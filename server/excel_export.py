from __future__ import annotations

import io
from datetime import datetime
from typing import Any

from openpyxl import Workbook
from openpyxl.chart import LineChart, Reference
from openpyxl.chart.trendline import Trendline
from openpyxl.styles import Alignment, Font, PatternFill
from openpyxl.utils import get_column_letter

def _poly_fit_values(timestamps: list[float], values: list[float]) -> list[float | None]:
    """Quadratic least-squares fit y = a + b t + c t^2; return fitted y for each t."""
    n = len(values)
    if n < 3:
        return [None] * n
    t0 = timestamps[0]
    xs = [t - t0 for t in timestamps]
    # Normal equations for degree-2 polynomial
    s0 = float(n)
    s1 = sum(xs)
    s2 = sum(x * x for x in xs)
    s3 = sum(x * x * x for x in xs)
    s4 = sum(x * x * x * x for x in xs)
    sy = sum(values)
    sxy = sum(x * y for x, y in zip(xs, values))
    sx2y = sum(x * x * y for x, y in zip(xs, values))

    # Solve 3x3 system A * [a,b,c]^T = [sy, sxy, sx2y]^T
    matrix = [
        [s0, s1, s2, sy],
        [s1, s2, s3, sxy],
        [s2, s3, s4, sx2y],
    ]
    for col in range(3):
        pivot = max(range(col, 3), key=lambda row: abs(matrix[row][col]))
        if abs(matrix[pivot][col]) < 1e-12:
            return [None] * n
        matrix[col], matrix[pivot] = matrix[pivot], matrix[col]
        scale = matrix[col][col]
        matrix[col] = [value / scale for value in matrix[col]]
        for row in range(3):
            if row == col:
                continue
            factor = matrix[row][col]
            matrix[row] = [matrix[row][i] - factor * matrix[col][i] for i in range(4)]
    a, b, c = matrix[0][3], matrix[1][3], matrix[2][3]
    return [round(a + b * x + c * x * x, 6) for x in xs]


def build_history_workbook(
    history: dict[int, list[dict[str, Any]]],
    *,
    hours: float = 24.0,
    max_meters: int = 20,
) -> bytes:
    workbook = Workbook()
    # Remove default sheet; recreate per meter for stable ordering
    default = workbook.active
    workbook.remove(default)

    header_font = Font(bold=True, color="FFFFFF")
    header_fill = PatternFill("solid", fgColor="1F6FB2")
    header_align = Alignment(horizontal="center", vertical="center")
    exported_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    for meter_id in range(1, max_meters + 1):
        sheet_name = f"百分表{meter_id:02d}"
        sheet = workbook.create_sheet(title=sheet_name)
        sheet["A1"] = f"百分表 {meter_id:02d} — 近 {int(hours)} 小时历史"
        sheet["A1"].font = Font(bold=True, size=13)
        sheet.merge_cells("A1:D1")
        sheet["A2"] = f"导出时间：{exported_at}"
        sheet.merge_cells("A2:D2")

        headers = ["时间", "读数(mm)", "拟合读数(mm)", "RSSI(dBm)"]
        for col, title in enumerate(headers, start=1):
            cell = sheet.cell(row=4, column=col, value=title)
            cell.font = header_font
            cell.fill = header_fill
            cell.alignment = header_align

        samples = history.get(meter_id) or []
        timestamps = [float(item["recorded_at"]) for item in samples]
        readings = [float(item["value_mm"]) for item in samples]
        fitted = _poly_fit_values(timestamps, readings)

        for index, sample in enumerate(samples):
            row = 5 + index
            sheet.cell(row=row, column=1, value=sample["recorded_at_iso"])
            sheet.cell(row=row, column=2, value=round(float(sample["value_mm"]), 4))
            fit_value = fitted[index]
            if fit_value is not None:
                sheet.cell(row=row, column=3, value=fit_value)
            sheet.cell(row=row, column=4, value=int(sample.get("ble_rssi") or 0))

        if not samples:
            sheet.cell(row=5, column=1, value="（近24小时无记录）")
        else:
            data_end = 4 + len(samples)
            chart = LineChart()
            chart.title = f"百分表{meter_id:02d} 读数与拟合曲线"
            chart.style = 10
            chart.y_axis.title = "读数 (mm)"
            chart.x_axis.title = "时间"
            chart.height = 12
            chart.width = 18
            chart.legend.position = "b"

            cats = Reference(sheet, min_col=1, min_row=5, max_row=data_end)
            values = Reference(sheet, min_col=2, min_row=4, max_row=data_end)
            chart.add_data(values, titles_from_data=True)
            chart.set_categories(cats)
            chart.series[0].trendline = Trendline(trendlineType="poly", order=2)

            if any(value is not None for value in fitted):
                fit_values = Reference(sheet, min_col=3, min_row=4, max_row=data_end)
                chart.add_data(fit_values, titles_from_data=True)
                if len(chart.series) > 1:
                    chart.series[1].graphicalProperties.line.dashStyle = "dash"

            sheet.add_chart(chart, "F4")

        sheet.column_dimensions["A"].width = 22
        sheet.column_dimensions["B"].width = 14
        sheet.column_dimensions["C"].width = 16
        sheet.column_dimensions["D"].width = 12
        for col in range(5, 12):
            sheet.column_dimensions[get_column_letter(col)].width = 12

    buffer = io.BytesIO()
    workbook.save(buffer)
    return buffer.getvalue()
