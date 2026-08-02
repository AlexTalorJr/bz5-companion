# зеркало на Python: та же арифметика, проверка детерминизма и формата
M=0xFFFFFFFFFFFFFFFF
def det(ms, seed):
    h=0xcbf29ce484222325
    for c in seed.encode(): h=((h^c)*0x100000001b3)&M
    b=[0]*16
    for i,sh in enumerate((40,32,24,16,8,0)): b[i]=(ms>>sh)&0xFF
    x=h
    for i in range(6,16):
        x=(x+0x9E3779B97F4A7C15)&M
        z=x
        z=((z^(z>>30))*0xBF58476D1CE4E5B9)&M
        z=((z^(z>>27))*0x94D049BB133111EB)&M
        z=z^(z>>31)
        b[i]=z&0xFF
    b[6]=0x70|(b[6]&0x0F); b[8]=0x80|(b[8]&0x3F)
    s=''.join(('-' if i in(4,6,8,10) else '')+f'{v:02x}' for i,v in enumerate(b))
    return s
a=det(1785573705000,'hal_bg|1785573705000|1785575717000')
b=det(1785573705000,'hal_bg|1785573705000|1785575717000')
c=det(1785573705000,'hal_bg|1785573705000|1785575718000')
print('повтор совпал:', a==b)
print('другое окно  :', a!=c)
print('версия 7     :', a[14]=='7')
print('вариант 10xx :', a[19] in '89ab')
print('пример       :', a)
