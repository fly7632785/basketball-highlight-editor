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
RIM_CX, RIM_Y, RIM_W = 240, 132, 14
SHOT_GOOD = (168, 50, 312, 226)
SHOT_BIG = (40, 24, 440, 290)
SHOT_SMALL = (225, 124, 255, 158)
NET_GOOD = (230, 134, 250, 158)


def s(v):
    return int(v * S)


def scene(d: ImageDraw.ImageDraw, figure: bool) -> None:
    d.rectangle([0, 0, s(W), s(H)], fill=(36, 44, 56))
    # 墙面与地板
    d.rectangle([0, s(250), s(W), s(H)], fill=(150, 104, 62))
    d.line([0, s(250), s(W), s(250)], fill=(110, 76, 44), width=s(2))
    # 缩小篮筐与篮板，模拟固定机位的画面比例。
    d.rectangle([s(150), s(96), s(330), s(134)], fill=(226, 230, 236), outline=(160, 168, 180), width=s(2))
    d.rectangle([s(229), s(113), s(251), s(133)], outline=(220, 70, 60), width=s(1))
    top_l, top_r = RIM_CX - RIM_W / 2, RIM_CX + RIM_W / 2
    bot_l, bot_r, bot_y = RIM_CX - 5, RIM_CX + 5, RIM_Y + 20
    d.polygon([(s(top_l), s(RIM_Y)), (s(top_r), s(RIM_Y)), (s(bot_r), s(bot_y)), (s(bot_l), s(bot_y))], outline=(235, 238, 242), width=s(1))
    for i in range(1, 4):
        t = i / 4
        d.line([s(top_l + (top_r - top_l) * t), s(RIM_Y), s(bot_l + (bot_r - bot_l) * t), s(bot_y)], fill=(235, 238, 242), width=s(1))
    for j in range(1, 4):
        t = j / 4
        d.line([s(top_l + (bot_l - top_l) * t), s(RIM_Y + 20 * t), s(top_r + (bot_r - top_r) * t), s(RIM_Y + 20 * t)], fill=(235, 238, 242), width=s(1))
    d.ellipse([s(top_l - 1), s(RIM_Y - 2), s(top_r + 1), s(RIM_Y + 3)], outline=(235, 110, 20), width=s(2))
    d.ellipse([s(235), s(91), s(245), s(101)], fill=(228, 120, 40), outline=(120, 56, 16), width=s(1))
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
    def width(rect): return rect[2] - rect[0]
    def height(rect): return rect[3] - rect[1]
    assert 0.25 <= width(SHOT_GOOD) / W <= 0.35
    assert 0.45 <= height(SHOT_GOOD) / H <= 0.60
    assert 8 <= width(SHOT_GOOD) / RIM_W <= 15
    assert 1.5 <= width(SHOT_SMALL) / RIM_W <= 3
    assert width(SHOT_SMALL) < W * 0.08 and height(SHOT_SMALL) < H * 0.12
    assert width(SHOT_BIG) > W * 0.5
    assert SHOT_GOOD[0] < NET_GOOD[0] < NET_GOOD[2] < SHOT_GOOD[2]
    assert SHOT_GOOD[1] < NET_GOOD[1] < NET_GOOD[3] < SHOT_GOOD[3]
    render("good", [(SHOT_GOOD, ORANGE, False), (NET_GOOD, WHITE, True)], True)
    render("too_big", [(SHOT_BIG, ORANGE, False)], False, figure=True)
    render("too_small", [(SHOT_SMALL, ORANGE, False)], False)
    render("net_good", [(NET_GOOD, WHITE, True)], True)
    render("net_too_big", [(SHOT_BIG, WHITE, True)], False, figure=True)
    render("net_too_small", [((230, 133, 250, 138), WHITE, True)], False)



if __name__ == "__main__":
    main()
