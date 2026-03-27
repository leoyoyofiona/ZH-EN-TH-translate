#!/usr/bin/env python3
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs' / 'install'
OUT.mkdir(parents=True, exist_ok=True)
ICON_PATH = ROOT / 'Resources' / 'AppIcon-base.png'

W, H = 1600, 980
BG_TOP = (246, 249, 255)
BG_BOTTOM = (235, 242, 255)
CARD = (255, 255, 255, 236)
TEXT = (28, 33, 45)
MUTED = (99, 108, 123)
ACCENT = (41, 127, 255)
ACCENT_2 = (13, 185, 208)
SUCCESS = (28, 176, 99)
WARNING = (244, 162, 44)
CODE_BG = (17, 24, 39)
CODE_TEXT = (222, 244, 255)
BORDER = (218, 227, 242)

TITLE_FONT = '/System/Library/Fonts/Hiragino Sans GB.ttc'
MONO_FONT = '/System/Library/Fonts/SFNSMono.ttf'
FALLBACK_MONO = '/System/Library/Fonts/Menlo.ttc'


def font(path, size):
    try:
        return ImageFont.truetype(path, size)
    except Exception:
        return ImageFont.load_default()


def wrap_text(draw, text, fnt, max_width):
    lines = []
    for paragraph in text.split('\n'):
        if not paragraph:
            lines.append('')
            continue
        current = ''
        for ch in paragraph:
            test = current + ch
            bbox = draw.textbbox((0, 0), test, font=fnt)
            if bbox[2] - bbox[0] <= max_width or not current:
                current = test
            else:
                lines.append(current)
                current = ch
        if current:
            lines.append(current)
    return lines


def rounded_rect(draw, xy, radius, fill, outline=None, width=1):
    draw.rounded_rectangle(xy, radius=radius, fill=fill, outline=outline, width=width)


def add_shadow(base, xy, radius=24, opacity=60):
    shadow = Image.new('RGBA', base.size, (0, 0, 0, 0))
    sdraw = ImageDraw.Draw(shadow)
    x0, y0, x1, y1 = xy
    sdraw.rounded_rectangle((x0 + 8, y0 + 12, x1 + 8, y1 + 12), radius=radius, fill=(25, 35, 55, opacity))
    shadow = shadow.filter(ImageFilter.GaussianBlur(18))
    base.alpha_composite(shadow)


def draw_header(draw, icon, step, title, subtitle):
    title_font = font(TITLE_FONT, 58)
    subtitle_font = font(TITLE_FONT, 28)
    pill_font = font(TITLE_FONT, 24)

    pill_x, pill_y = 90, 62
    rounded_rect(draw, (pill_x, pill_y, pill_x + 118, pill_y + 48), 24, fill=(225, 238, 255), outline=None)
    draw.text((pill_x + 24, pill_y + 10), step, font=pill_font, fill=ACCENT)

    draw.text((230, 62), title, font=title_font, fill=TEXT)
    draw.text((230, 132), subtitle, font=subtitle_font, fill=MUTED)
    icon_r = icon.resize((108, 108))
    return icon_r


def draw_bullets(draw, x, y, items, width, bullet_color=ACCENT):
    bullet_font = font(TITLE_FONT, 30)
    text_font = font(TITLE_FONT, 28)
    y_cursor = y
    for item in items:
        draw.ellipse((x, y_cursor + 10, x + 12, y_cursor + 22), fill=bullet_color)
        lines = wrap_text(draw, item, text_font, width - 32)
        for idx, line in enumerate(lines):
            draw.text((x + 28, y_cursor + idx * 38), line, font=text_font, fill=TEXT)
        y_cursor += max(44, len(lines) * 38) + 16
    return y_cursor


def make_card(filename, step, title, subtitle, body_builder):
    base = Image.new('RGBA', (W, H), BG_TOP + (255,))
    px = base.load()
    for y in range(H):
        ratio = y / max(1, H - 1)
        r = int(BG_TOP[0] * (1 - ratio) + BG_BOTTOM[0] * ratio)
        g = int(BG_TOP[1] * (1 - ratio) + BG_BOTTOM[1] * ratio)
        b = int(BG_TOP[2] * (1 - ratio) + BG_BOTTOM[2] * ratio)
        for x in range(W):
            px[x, y] = (r, g, b, 255)
    draw = ImageDraw.Draw(base)

    icon = Image.open(ICON_PATH).convert('RGBA')
    icon_small = draw_header(draw, icon, step, title, subtitle)
    base.alpha_composite(icon_small, (1440, 52))

    card_xy = (72, 210, W - 72, H - 68)
    add_shadow(base, card_xy, radius=34, opacity=65)
    draw = ImageDraw.Draw(base)
    rounded_rect(draw, card_xy, 34, fill=CARD, outline=BORDER, width=2)

    body_builder(base, draw)
    path = OUT / filename
    base.convert('RGB').save(path, quality=95)
    print(path)


def card_download(base, draw):
    left = 120
    top = 268
    section_title = font(TITLE_FONT, 34)
    draw.text((left, top), '推荐下载位置', font=section_title, fill=TEXT)
    draw.text((left, top + 54), 'GitHub Release 页面', font=font(TITLE_FONT, 28), fill=MUTED)

    release_box = (left, top + 110, 980, top + 330)
    rounded_rect(draw, release_box, 24, fill=(245, 249, 255), outline=BORDER, width=2)
    draw.text((left + 34, top + 140), '仓库', font=font(TITLE_FONT, 24), fill=MUTED)
    draw.text((left + 34, top + 180), 'leoyoyofiona/ZH-EN-TH-translate', font=font(TITLE_FONT, 34), fill=TEXT)
    draw.text((left + 34, top + 238), 'Release 标签', font=font(TITLE_FONT, 24), fill=MUTED)
    draw.text((left + 34, top + 276), 'v0.1.2', font=font(TITLE_FONT, 34), fill=ACCENT)

    url = 'https://github.com/leoyoyofiona/ZH-EN-TH-translate/releases/tag/v0.1.2'
    lines = wrap_text(draw, url, font(TITLE_FONT, 24), 780)
    y = top + 354
    draw.text((left, y), '打开这个地址下载：', font=font(TITLE_FONT, 28), fill=TEXT)
    for i, line in enumerate(lines):
        draw.text((left, y + 40 + i * 30), line, font=font(TITLE_FONT, 22), fill=ACCENT)

    right = 1040
    file_box = (right, top + 40, W - 120, top + 380)
    rounded_rect(draw, file_box, 26, fill=(255, 255, 255), outline=BORDER, width=2)
    draw.text((right + 32, top + 72), '请选择这个文件', font=section_title, fill=TEXT)
    rounded_rect(draw, (right + 32, top + 136, W - 152, top + 232), 18, fill=(235, 245, 255), outline=None)
    file_font = font(TITLE_FONT, 23)
    yy = top + 162
    for line in wrap_text(draw, 'multilingual-live-translator-v0.1.2-macOS.dmg', file_font, 300):
        draw.text((right + 54, yy), line, font=file_font, fill=ACCENT)
        yy += 30
    draw.text((right + 32, top + 266), '备用：ZIP 版本', font=font(TITLE_FONT, 24), fill=MUTED)
    yy = top + 302
    zip_font = font(TITLE_FONT, 20)
    for line in wrap_text(draw, 'multilingual-live-translator-v0.1.2-macOS.zip', zip_font, 318):
        draw.text((right + 32, yy), line, font=zip_font, fill=TEXT)
        yy += 26

    draw_bullets(draw, left, top + 468, [
        '优先下载 DMG，安装路径更直观。',
        '如果朋友看到多个版本，只下载 v0.1.2。',
        '不要再下载旧版 v0.1.1。'
    ], width=1320)


def card_drag(base, draw):
    left = 120
    top = 268
    draw.text((left, top), '打开 DMG 后这样拖动', font=font(TITLE_FONT, 36), fill=TEXT)

    app_box = (180, 390, 580, 760)
    app_inner = (230, 450, 530, 700)
    add_shadow(base, app_box, radius=34, opacity=40)
    rounded_rect(draw, app_box, 34, fill=(249, 252, 255), outline=BORDER, width=2)
    icon = Image.open(ICON_PATH).convert('RGBA').resize((180, 180))
    base.alpha_composite(icon, (290, 470))
    draw.text((252, 680), '多国语言同声翻译.app', font=font(TITLE_FONT, 28), fill=TEXT)

    folder_box = (1010, 390, 1410, 760)
    add_shadow(base, folder_box, radius=34, opacity=40)
    rounded_rect(draw, folder_box, 34, fill=(249, 252, 255), outline=BORDER, width=2)
    draw.rounded_rectangle((1100, 495, 1320, 660), radius=24, fill=(100, 158, 255), outline=None)
    draw.rounded_rectangle((1128, 462, 1222, 530), radius=18, fill=(132, 181, 255), outline=None)
    draw.text((1116, 682), 'Applications', font=font(TITLE_FONT, 34), fill=TEXT)

    arrow_y = 570
    draw.line((630, arrow_y, 970, arrow_y), fill=ACCENT, width=16)
    draw.polygon([(970, arrow_y), (920, arrow_y - 34), (920, arrow_y + 34)], fill=ACCENT)
    draw.text((690, 506), '拖进去', font=font(TITLE_FONT, 38), fill=ACCENT)

    draw_bullets(draw, left, 812, [
        '先双击打开 DMG，再把 app 拖到 Applications。',
        '之后从 Applications 里打开，不要直接在 DMG 里运行。'
    ], width=1320)


def card_terminal(base, draw):
    left = 120
    top = 268
    draw.text((left, top), '如果首次打开被 macOS 拦截', font=font(TITLE_FONT, 36), fill=TEXT)
    draw.text((left, top + 54), '在“终端”里执行一次解除隔离命令', font=font(TITLE_FONT, 28), fill=MUTED)

    term_box = (120, 360, 1480, 760)
    add_shadow(base, term_box, radius=34, opacity=40)
    rounded_rect(draw, term_box, 28, fill=CODE_BG, outline=(42, 54, 72), width=2)
    draw.text((152, 392), 'Terminal', font=font(TITLE_FONT, 28), fill=(172, 183, 201))
    cmd = 'xattr -dr com.apple.quarantine "/Applications/多国语言同声翻译.app"'
    code_font = font(TITLE_FONT, 30)
    lines = wrap_text(draw, cmd, code_font, 1180)
    y = 490
    for line in lines:
        draw.text((162, y), line, font=code_font, fill=CODE_TEXT)
        y += 48

    rounded_rect(draw, (120, 800, 430, 870), 20, fill=(236, 248, 241), outline=None)
    draw.text((148, 821), '只需要执行一次', font=font(TITLE_FONT, 30), fill=SUCCESS)
    draw_bullets(draw, 470, 800, [
        '执行完成后再双击打开应用。',
        '如果朋友没有看到拦截提示，这一步也可以先做，结果一样。'
    ], width=1000, bullet_color=SUCCESS)


def card_permissions(base, draw):
    left = 120
    top = 268
    draw.text((left, top), '首次打开后按提示授权', font=font(TITLE_FONT, 36), fill=TEXT)
    draw.text((left, top + 54), '只要按功能需要授权一次，后面不需要重复设置', font=font(TITLE_FONT, 28), fill=MUTED)

    col1 = (120, 382, 510, 770)
    col2 = (565, 382, 955, 770)
    col3 = (1010, 382, 1400, 770)
    for box, color, title, body in [
        (col1, (232, 242, 255), '屏幕录制', '系统音频模式需要\n看视频、会议软件声音时要开'),
        (col2, (236, 248, 241), '麦克风', '麦克风模式需要\n对着电脑讲话时要开'),
        (col3, (255, 247, 232), '语音识别', '所有识别模式都需要\n不管系统音频还是麦克风都要开'),
    ]:
        add_shadow(base, box, radius=28, opacity=36)
        rounded_rect(draw, box, 28, fill=color, outline=BORDER, width=2)
        draw.text((box[0] + 28, box[1] + 34), title, font=font(TITLE_FONT, 34), fill=TEXT)
        lines = wrap_text(draw, body, font(TITLE_FONT, 26), 320)
        yy = box[1] + 110
        for line in lines:
            draw.text((box[0] + 28, yy), line, font=font(TITLE_FONT, 26), fill=MUTED)
            yy += 38

    draw_bullets(draw, left, 812, [
        '如果某种语言提示需要下载翻译语言：打开 系统设置 -> 通用 -> 语言与地区 -> 翻译语言。',
        '下载完成后重新回到应用即可开始使用。'
    ], width=1320, bullet_color=WARNING)


make_card('step-1-download-release.png', 'STEP 1', '从 GitHub Release 下载安装包', '先找到正确的 v0.1.2 安装文件', card_download)
make_card('step-2-drag-to-applications.png', 'STEP 2', '把应用拖到 Applications', '不要直接在 DMG 里运行', card_drag)
make_card('step-3-remove-quarantine.png', 'STEP 3', '首次打开前移除隔离属性', '没有 Developer ID 时，这一步必需', card_terminal)
make_card('step-4-grant-permissions.png', 'STEP 4', '首次授权并下载所需语言资源', '授权一次后就可以长期使用', card_permissions)
