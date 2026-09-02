from PIL import Image

img = Image.open(r'C:\Users\DMJ\Desktop\app-icon-clean.png').convert('RGB')
w, h = img.size
pixels = img.load()

# 分别取四个角圆角内的蓝色
corner_colors = {
    'tl': img.getpixel((300, 300)),  # 左上角
    'tr': img.getpixel((w-300, 300)),  # 右上角
    'bl': img.getpixel((300, h-300)),  # 左下角
    'br': img.getpixel((w-300, h-300)),  # 右下角
}
print(f'四角颜色: {corner_colors}')

corner_size = 280

# 左上角
for y in range(corner_size):
    for x in range(corner_size):
        r,g,b = pixels[x,y]
        if r > 230 and g > 230 and b > 230:
            pixels[x,y] = corner_colors['tl']

# 右上角
for y in range(corner_size):
    for x in range(w-corner_size, w):
        r,g,b = pixels[x,y]
        if r > 230 and g > 230 and b > 230:
            pixels[x,y] = corner_colors['tr']

# 左下角
for y in range(h-corner_size, h):
    for x in range(corner_size):
        r,g,b = pixels[x,y]
        if r > 230 and g > 230 and b > 230:
            pixels[x,y] = corner_colors['bl']

# 右下角
for y in range(h-corner_size, h):
    for x in range(w-corner_size, w):
        r,g,b = pixels[x,y]
        if r > 230 and g > 230 and b > 230:
            pixels[x,y] = corner_colors['br']

img.save(r'C:\Users\DMJ\Desktop\app-icon-square.png')
print('已保存正方形图标')
for x,y in [(0,0),(w-1,0),(0,h-1),(w-1,h-1)]:
    print(f'角({x},{y}): {img.getpixel((x,y))}')
