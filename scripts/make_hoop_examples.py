"""生成导入页「框选篮筐」示例图（本地绘制的示意图，不含任何比赛画面）。

用法：python scripts/make_hoop_examples.py
输出：apps/desktop/assets/hoop_example/{good,too_big,too_small}.png
"""
from pathlib import Path

from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parent.parent / "apps/desktop/assets/hoop_example"
W, H, S = 480, 320, 3  # 画 3 倍大再缩小，边缘更平滑
ORANGE = (240, 140, 0)
WHITE = (255, 255, 255)
GREEN = (46, 160, 90)
RED = (214, 69, 65)

# 篮筐位置（480x320 坐标系）
RIM_CX, RIM_Y, RIM_W = 240, 118, 56


def s(v):
    return int(v * S)


def scene(d: ImageDraw.ImageDraw, figure: bool) -> None:
    d.rectangle([0, 0, s(W), s(H)], fill=(36, 44, 56))
    # 墙面与地板
    d.rectangle([0, s(250), s(W), s(H)], fill=(150, 104, 62))
    d.line([0, s(250), s(W), s(250)], fill=(110, 76, 44), width=s(2))
    # 篮板
    d.rectangle([s(RIM_CX - 78), s(40), s(RIM_CX + 78), s(RIM_Y + 8)], fill=(226, 230, 236), outline=(160, 168, 180), width=s(2))
    d.rectangle([s(RIM_CX - 26), s(78), s(RIM_CX + 26), s(RIM_Y + 4)], outline=(220, 70, 60), width=s(3))
    # 篮网（梯形 + 网格线）
    top_l, top_r = RIM_CX - RIM_W / 2, RIM_CX + RIM_W / 2
    bot_l, bot_r, bot_y = RIM_CX - 18, RIM_CX + 18, RIM_Y + 62
    d.polygon([(s(top_l), s(RIM_Y)), (s(top_r), s(RIM_Y)), (s(bot_r), s(bot_y)), (s(bot_l), s(bot_y))], outline=(235, 238, 242), width=s(2))
    for i in range(1, 6):
        t = i / 6
        d.line([s(top_l + (top_r - top_l) * t), s(RIM_Y), s(bot_l + (bot_r - bot_l) * t), s(bot_y)], fill=(235, 238, 242), width=s(1))
    for j in range(1, 4):
        y = RIM_Y + 62 * j / 4
        k = j / 4
        d.line([s(top_l + (bot_l - top_l) * k), s(y), s(top_r + (bot_r - top_r) * k), s(y)], fill=(235, 238, 242), width=s(1))
    # 篮圈
    d.ellipse([s(top_l - 2), s(RIM_Y - 6), s(top_r + 2), s(RIM_Y + 8)], outline=(235, 110, 20), width=s(4))
    # 球
    d.ellipse([s(RIM_CX - 13), s(RIM_Y - 52), s(RIM_CX + 13), s(RIM_Y - 26)], fill=(228, 120, 40), outline=(120, 56, 16), width=s(2))
    if figure:
        # 球员剪影：说明框太大会把人也框进去
        d.ellipse([s(96), s(156), s(116), s(176)], fill=(200, 208, 220))
        d.rectangle([s(98), s(178), s(114), s(236)], fill=(200, 208, 220))
        d.ellipse([s(356), s(168), s(376), s(188)], fill=(200, 208, 220))
        d.rectangle([s(358), s(190), s(374), s(246)], fill=(200, 208, 220))


def box(d, rect, color, width=4, dash=False):
    x1, y1, x2, y2 = (s(v) for v in rect)
    if not dash:
        d.rounded_rectangle([x1, y1, x2, y2], radius=s(6), outline=color, width=s(width))
        return
    step = s(10)
    for x in range(x1, x2, step * 2):
        d.line([x, y1, min(x + step, x2), y1], fill=color, width=s(width))
        d.line([x, y2, min(x + step, x2), y2], fill=color, width=s(width))
    for y in range(y1, y2, step * 2):
        d.line([x1, y, x1, min(y + step, y2)], fill=color, width=s(width))
        d.line([x2, y, x2, min(y + step, y2)], fill=color, width=s(width))


def badge(d, ok: bool) -> None:
    cx, cy, r = 38, 38, 22
    d.ellipse([s(cx - r), s(cy - r), s(cx + r), s(cy + r)], fill=GREEN if ok else RED)
    if ok:
        d.line([s(cx - 10), s(cy + 1), s(cx - 3), s(cy + 9), s(cx + 11), s(cy - 8)], fill=WHITE, width=s(5), joint="curve")
    else:
        d.line([s(cx - 9), s(cy - 9), s(cx + 9), s(cy + 9)], fill=WHITE, width=s(5))
        d.line([s(cx - 9), s(cy + 9), s(cx + 9), s(cy - 9)], fill=WHITE, width=s(5))


def render(name: str, boxes, ok: bool, figure: bool = False) -> None:
    img = Image.new("RGB", (s(W), s(H)))
    d = ImageDraw.Draw(img)
    scene(d, figure)
    for rect, color, dash in boxes:
        box(d, rect, color, dash=dash)
    badge(d, ok)
    img = img.resize((W, H), Image.LANCZOS).quantize(colors=64, method=Image.Quantize.MEDIANCUT)
    img.save(OUT / f"{name}.png", optimize=True)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    # 正确：橙色框盖住来球轨迹、篮圈和网下落球范围；白色框只盖篮网
    render("good", [((190, 62, 290, 206), ORANGE, False), ((206, 112, 274, 194), WHITE, True)], True)
    # 太大：把整块篮板、球员和地面都框进去
    render("too_big", [((40, 24, 440, 290), ORANGE, False)], False, figure=True)
    # 太小：只框住篮圈，球一靠近或落下就出框
    render("too_small", [((210, 106, 270, 134), ORANGE, False)], False)
    # 白色检测区只框篮网；错误示例分别包括篮板地面及只有网口。
    render("net_good", [((206, 122, 274, 190), WHITE, True)], True)
    render("net_too_big", [((40, 24, 440, 290), WHITE, True)], False, figure=True)
    render("net_too_small", [((210, 120, 270, 132), WHITE, True)], False)


if __name__ == "__main__":
    main()
