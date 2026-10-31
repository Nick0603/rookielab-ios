import sys, os
# 商店截圖加標題：python3 ios/store/frame.py <模擬器截圖資料夾> <輸出資料夾>（截圖用 1320×2868 的 6.9 吋模擬器拍，見 ios/store/zh-Hant.md）
SRC, OUT = sys.argv[1], sys.argv[2]
from PIL import Image, ImageDraw, ImageFont, ImageFilter
F='/System/Library/AssetsV2/com_apple_MobileAsset_Font8/86ba2c91f017a3749571a82f2c6d890ac7ffb2fb.asset/AssetData/PingFang.ttc'
def face(want):
    for i in range(40):
        try:
            f=ImageFont.truetype(F,10,index=i)
            if f.getname()==want: return i
        except OSError: break
TB=face(('PingFang TC','Semibold')); TR=face(('PingFang TC','Regular'))
W,H=1320,2868; CREAM=(255,247,239); TEAL=(31,111,120); ORANGE=(232,113,31); INK=(42,37,34)
shots=[('2-quick','停在重點，換你找找看','錯過的機會，當下就變成一堂課'),
       ('3-wrong','走錯了也沒關係','先看對手怎麼回應，再試一次'),
       ('4-compare','好在哪、差在哪','候選步各走兩步，一眼看懂'),
       ('5-puzzle','每天 5 題，從你的棋來','錯過的機會自動變成練習題'),
       ('7-report','一次看最近 10 盤','準確率、常見問題、先練什麼'),
       ('6-endgame','殘局一步一步學','看要領、看示範，再跟引擎練')]
for n,(f,title,sub) in enumerate(shots,1):
    c=Image.new('RGB',(W,H),CREAM); d=ImageDraw.Draw(c)
    ft=ImageFont.truetype(F,104,index=TB); fs=ImageFont.truetype(F,58,index=TR)
    d.text((W/2,250),title,font=ft,fill=TEAL,anchor='mm')
    d.text((W/2,390),sub,font=fs,fill=INK,anchor='mm')
    s=Image.open(os.path.join(SRC, f+'.png')).convert('RGB'); sw=1040; sh=int(s.height*sw/s.width); s=s.resize((sw,sh),Image.LANCZOS)
    x,y=(W-sw)//2,520; r=70
    sh_=Image.new('L',(W,H),0); ImageDraw.Draw(sh_).rounded_rectangle((x,y+24,x+sw,y+sh+24),r,fill=90); sh_=sh_.filter(ImageFilter.GaussianBlur(40))
    c.paste(Image.new('RGB',(W,H),(200,170,150)),(0,0),sh_)
    m=Image.new('L',(sw,sh),0); ImageDraw.Draw(m).rounded_rectangle((0,0,sw,sh),r,fill=255)
    c.paste(s,(x,y),m)
    ImageDraw.Draw(c).rounded_rectangle((x,y,x+sw,y+sh),r,outline=INK,width=10)
    c.save(os.path.join(OUT, f'store-{n}.png'))
