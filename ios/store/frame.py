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
# 第三個參數 en 換英文標題（1.1.0 起：單局復盤）
LANG=sys.argv[3] if len(sys.argv)>3 else 'zh'
shots={'zh':[('4-find','停在改變局勢的那一步','你的關鍵步，換你找找看'),
             ('2-opening','這局下的是什麼開局','理論走到第幾手、你的戰績'),
             ('3-stop','雙方的關鍵步都講清楚','牽制、保護、最佳步畫在棋盤上'),
             ('5-summary','看完一局，重點一次回顧','點一下回到那一步'),
             ('1-home','下完一盤，馬上復盤','輸入帳號或貼上棋譜就能開始')],
       'en':[('4-find','Stops where the game turned','Find the better move yourself'),
             ('2-opening','Know your opening','Book depth and your record'),
             ('3-stop','Key moves for both sides','Pins, defenses and the best move'),
             ('5-summary','All your key moments','Tap to jump back to any move'),
             ('1-home','Your last game, explained','Enter a username or paste a PGN')]}[LANG]
shots=[x for x in shots if os.path.exists(os.path.join(SRC, x[0]+'.png'))]
for n,(f,title,sub) in enumerate(shots,1):
    c=Image.new('RGB',(W,H),CREAM); d=ImageDraw.Draw(c)
    size=104
    while ImageFont.truetype(F,size,index=TB).getlength(title)>W-120: size-=4
    ft=ImageFont.truetype(F,size,index=TB); fs=ImageFont.truetype(F,58,index=TR)
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
