/* ============================================================
   华夏五千年 · 历史疆域时间地图 —— 应用引擎
   (无依赖, 纯 SVG/DOM; 数据见 data/*.js)
   ============================================================ */
(function(){
'use strict';

/* ---------- 时间工具 ---------- */
var T0 = -8000, T1 = 2026.5;             // 时间轴范围 (至今)
var MDAYS=[31,28,31,30,31,30,31,31,30,31,30,31];
var MCUM=[0]; for(var i=0;i<11;i++) MCUM.push(MCUM[i]+MDAYS[i]);

function yearOf(t){ return Math.floor(t); }
function ymd(t){
  var y=Math.floor(t), f=t-y;
  var doy=Math.min(364, Math.max(0, Math.round(f*365)));
  var m=0; while(m<11 && doy>=MCUM[m+1]) m++;
  return {y:y, m:m+1, d:doy-MCUM[m]+1};
}
function fmtY(y){ return y<=0 ? '前'+(-y+ (y===0?1:0))+'年' : y+'年'; }
function fmtDate(t, span){
  var o=ymd(t);
  if(span===undefined) span=1e9;
  if(span>2.2) return fmtY(o.y);
  if(span>0.45) return fmtY(o.y)+' '+o.m+'月';
  return fmtY(o.y)+' '+o.m+'月'+o.d+'日';
}
function fmtRange(a,b){
  if(b-a<1.5){ var A=ymd(a),B=ymd(b); return fmtY(A.y)+A.m+'月'+A.d+'日 — '+fmtY(B.y)+B.m+'月'+B.d+'日'; }
  return fmtY(yearOf(a))+' — '+fmtY(yearOf(b));
}
function durText(a,b){
  var n=b-a;
  if(n<0.02) return Math.max(1,Math.round(n*365))+'天';
  if(n<1) return Math.round(n*12)+'个月';
  return Math.round(n)+'年';
}

/* ---------- 投影 ---------- */
var LON=68, LAT=56, SX=12.5, SY=12.5/Math.cos(32*Math.PI/180);
var W=1000, H=Math.round((56-6)*SY);
function PX(lon){ return (lon-LON)*SX; }
function PY(lat){ return (LAT-lat)*SY; }
function pathOf(rings){
  var d='';
  rings.forEach(function(r){
    r.forEach(function(p,i){ d+=(i?'L':'M')+PX(p[0]).toFixed(2)+' '+PY(p[1]).toFixed(2); });
    d+='Z';
  });
  return d;
}
/* ---------- 疆域精化: 栅格化 → 归属 → 闭运算缝合 → 碎块清理 → 描迹平滑 ----------
   政权疆界数据是低分辨率手绘概形, 直接叠画会在国与国之间留缝、彼此重叠、
   沿海露地、甩出碎屑。渲染前把当前时刻所有政权栅格化到 0.15° 经纬网格,
   在格上把归属判干净, 再描迹成平滑的边界:
     1  栅格化   每国多边形按扫描线落格, 同时记下自己的格号清单;
     2  归属判定 重叠格唯一归属: 面积小者优先(飞地小国不被大邻国吞没);
                帧标记 ov:1 的政权(拉锯/占领区)不参与争夺, 其与他国的
                重叠区另行描迹, 以双色斜纹渲染;
     3  最近国场 一趟带标记的桶式 Dijkstra: 每个无主格"绕开他国、沿陆地"
                可达的最近政权及距离(跨海代价×4, 归属不会漂到海峡对岸);
     4  闭运算   形态学闭运算认缝: 离所有政权都远的无主陆地才算真正的空白
                (草原、未收录的邻邦); 凡与空白相距 > R 的无主陆地一律缝合
                给最近政权 —— 窄廊、三国交界的楔形、国界与海岸间的死角都在
                其中。取代旧的"两国距离和 ≤ 常数"判据, 不再因缝略宽或夹在
                三国之间而漏填;
     5  内袋填充 完全被陆地围住(不触图边、不临海)的无主区块整块划归四邻,
                消除"国中空心";
     6  多数表决 抹平距离场等值线的锯齿、清掉孤立小块;
     7  掐点弥合 只在 2×2 对角相接的格子就地补一格或让一格, 否则描迹会得到
                蝴蝶结式自交;
     8  碎块清理 各国只留成规模的连通块, 算法切出的碎屑并入接壤最长的邻国;
                孤悬海外而无陆邻的小岛保留;
     9  近岸外扩 向海外扩两格, 最终被陆地剪裁, 保证覆盖到真实海岸线;
    10  交汇点   标出三方(含空地)交汇的格点, 平滑时钉住;
    11  描迹平滑 沿格线描迹成环(内部恒在同侧) → 滤掉针尖小环 → 按格宽重采样
                → Taubin 低通 → Chaikin 切角 → Douglas-Peucker 抽稀。
                每一步都对遍历方向对称, 且误差有硬上限, 相邻两国沿共享格线
                得到的曲线仍逐点重合, 缝合处不会裂开;
    12  标注锚点 取各国"最深处"(到异属格距离最大的格)作为国号落点;
    13  斜纹层   ov 政权与他国的重叠区。 */
var CHAIKIN_IT=2;      // 收尾的 Chaikin 切角次数
var TAUBIN_IT=6;       // Taubin(λ/μ) 低通趟数 —— 平滑宽度约 2.5 格且不收缩
var TAU_L=0.58, TAU_M=-0.62;
var CELL=0.15, GLON0=64, GLAT0=6, GNX=560, GNY=334;
var KX=[1,-1,0,0,1,1,-1,-1], KY=[0,0,1,-1,1,-1,1,-1], KC=[10,10,10,10,14,14,14,14];
function GU(deg){ return Math.round(deg/CELL*10); }  // 度 → 距离场单位(正交步=10, 斜向14)
var FILLD=GU(2.0);        // 政权最大外扩 ≈2.0°
var FILLP=GU(0.7);        // 史前文化外扩上限 ≈0.7°
var CLOSE_R=GU(1.3);      // 闭运算半径: 可缝合的缝隙宽度 ≈2.6°
var OWNER_R=GU(2.4);      // 最近国场搜索半径 (只需覆盖最大外扩 FILLD)
var SEAMUL=4;             // 跨海代价倍率
var MINCELL=5;            // 绝对丢弃: 小于此格数的碎屑直接抹去
var MINCOMP=48;           // 并入邻国: 小于此格数且与他国接壤的连通块
var MINRING=9.0;          // 描迹环最小面积 (投影 px², 单格≈4.1), 滤掉针尖与单格斑点
var landMask=null;
var juncMask=null;        // 三方交汇的格点, 平滑时钉住 (见第10步)
var coastSea=null;        // 距陆地两格以内的海格 (近岸外扩只需扫这些)

// 扫描线栅格化: 对每一格行求多边形交点, 中心落入区间的格子回调
function scanRings(rings, mark){
  for(var gy=0;gy<GNY;gy++){
    var lat=GLAT0+(gy+0.5)*CELL, xs=[];
    for(var ri=0;ri<rings.length;ri++){
      var r=rings[ri];
      for(var i=0,j=r.length-1;i<r.length;j=i++){
        if((r[i][1]>lat)!==(r[j][1]>lat))
          xs.push(r[i][0]+(lat-r[i][1])/(r[j][1]-r[i][1])*(r[j][0]-r[i][0]));
      }
    }
    if(!xs.length) continue;
    xs.sort(function(a,b){return a-b;});
    for(var k=0;k+1<xs.length;k+=2){
      var g0=Math.max(0,Math.ceil((xs[k]-GLON0)/CELL-0.5));
      var g1=Math.min(GNX-1,Math.floor((xs[k+1]-GLON0)/CELL-0.5));
      for(var gx=g0;gx<=g1;gx++) mark(gx,gy);
    }
  }
}
function buildLandGrid(){
  var N=GNX*GNY, c, cx, cy, dx, dy;
  landMask=new Uint8Array(N);
  scanRings(BASEMAP.land,function(gx,gy){ landMask[gy*GNX+gx]=1; });
  var near=[];
  for(c=0;c<N;c++){
    if(landMask[c]) continue;
    cx=c%GNX; cy=(c-cx)/GNX;
    var hit=false;
    for(dy=-2;dy<=2&&!hit;dy++)for(dx=-2;dx<=2;dx++){
      var nx=cx+dx, ny=cy+dy;
      if(nx<0||ny<0||nx>=GNX||ny>=GNY) continue;
      if(landMask[ny*GNX+nx]){ hit=true; break; }
    }
    if(hit) near.push(c);
  }
  coastSea=Int32Array.from(near);
}
// 带标记的桶式 Dijkstra: 以各国边界格为源, 只在无主格中扩散
// (故不会"穿过"别国), 陆地代价1、海面代价 SEAMUL。返回最近国编号与距离。
function ownerField(owner,maxd){
  var N=GNX*GNY, nd=new Uint16Array(N), no=new Int16Array(N), buckets=[], seeds=[], c;
  nd.fill(0xFFFF); no.fill(-1);
  for(c=0;c<N;c++){
    if(owner[c]<0) continue;
    var sx=c%GNX, sy=(c-sx)/GNX, edge=false;
    for(var k0=0;k0<8&&!edge;k0++){
      var ax=sx+KX[k0], ay=sy+KY[k0];
      if(ax<0||ay<0||ax>=GNX||ay>=GNY) continue;
      if(owner[ay*GNX+ax]<0) edge=true;
    }
    if(edge){ nd[c]=0; no[c]=owner[c]; seeds.push(c); }
  }
  buckets[0]=seeds;
  for(var d=0;d<=maxd;d++){
    var q=buckets[d]; if(!q) continue;
    for(var qi=0;qi<q.length;qi++){
      c=q[qi]; if(nd[c]!==d) continue;
      var cx=c%GNX, cy=(c-cx)/GNX;
      for(var k=0;k<8;k++){
        var nx=cx+KX[k], ny=cy+KY[k];
        if(nx<0||ny<0||nx>=GNX||ny>=GNY) continue;
        var nc=ny*GNX+nx;
        if(owner[nc]>=0) continue;
        var v=d+KC[k]*(landMask[nc]?1:SEAMUL);
        if(v<=maxd&&v<nd[nc]){ nd[nc]=v; no[nc]=no[c]; (buckets[v]||(buckets[v]=[])).push(nc); }
      }
    }
  }
  return {d:nd,o:no};
}
// 桶式距离场: 自 seeds 起沿陆地扩散 (海面阻断) —— 求"到空白之地的距离"
function landDist(seeds,maxd){
  var nd=new Uint16Array(GNX*GNY), buckets=[], c;
  nd.fill(0xFFFF);
  for(c=0;c<seeds.length;c++) nd[seeds[c]]=0;
  buckets[0]=seeds.slice();
  for(var d=0;d<=maxd;d++){
    var q=buckets[d]; if(!q) continue;
    for(var qi=0;qi<q.length;qi++){
      c=q[qi]; if(nd[c]!==d) continue;
      var cx=c%GNX, cy=(c-cx)/GNX;
      for(var k=0;k<8;k++){
        var nx=cx+KX[k], ny=cy+KY[k];
        if(nx<0||ny<0||nx>=GNX||ny>=GNY) continue;
        var nc=ny*GNX+nx;
        if(!landMask[nc]) continue;
        var v=d+KC[k];
        if(v<=maxd&&v<nd[nc]){ nd[nc]=v; (buckets[v]||(buckets[v]=[])).push(nc); }
      }
    }
  }
  return nd;
}
// 二值格集描迹: 沿格线走边(内部恒在同侧), 输出经纬度环; 直行段就地合并
function traceMask(mask){
  var W1=GNX+1, DX=[1,0,-1,0], DY=[0,1,0,-1];
  var out={}, key;
  function add(cx,cy,d){ var k=cy*W1+cx; if(out[k]) out[k].push(d); else out[k]=[d]; }
  for(var y=0;y<GNY;y++){
    var row=y*GNX;
    for(var x=0;x<GNX;x++){
      if(!mask[row+x]) continue;
      if(x===0||!mask[row+x-1]) add(x,y+1,3);
      if(x===GNX-1||!mask[row+x+1]) add(x+1,y,1);
      if(y===0||!mask[row+x-GNX]) add(x,y,0);
      if(y===GNY-1||!mask[row+x+GNX]) add(x+1,y+1,2);
    }
  }
  var rings=[];
  for(key in out){
    for(;;){
      var lst=out[key];
      if(!lst||!lst.length) break;
      var start=+key, cd=lst.pop();
      var px=start%W1, py=(start-px)/W1;
      var pts=[], lastd=-1;
      for(;;){
        if(cd!==lastd){ pts.push([GLON0+px*CELL, GLAT0+py*CELL]); lastd=cd; }
        px+=DX[cd]; py+=DY[cd];
        var ck=py*W1+px;
        if(ck===start) break;
        var l2=out[ck], nd=-1;
        if(l2&&l2.length){
          var pref=[(cd+1)&3, cd, (cd+3)&3, (cd+2)&3];
          for(var pi=0;pi<4;pi++){
            var ii=l2.indexOf(pref[pi]);
            if(ii>=0){ nd=pref[pi]; l2.splice(ii,1); break; }
          }
        }
        if(nd<0) break;
        cd=nd;
      }
      if(pts.length>=4) rings.push(pts);
    }
  }
  return rings;
}
function ringAreaPx(r){
  var a=0;
  for(var i=0,j=r.length-1;i<r.length;j=i++)
    a+=PX(r[j][0])*PY(r[i][1])-PX(r[i][0])*PY(r[j][1]);
  return a/2;
}
// 按格宽重采样: 描迹环的每条边都是整数格长的直线段, 逐格插点后所有顶点间距
// 相等且与方向无关 —— 这样低通的"平滑宽度"才有确定的格数含义, 反向遍历所得
// 点集完全相同, 共享边界两侧仍逐点重合。同时标出落在"交汇点"上的顶点。
function densifyRing(r){
  var pts=[], fix=[], n=r.length, W1=GNX+1, i, k;
  for(i=0;i<n;i++){
    var p=r[i], q=r[(i+1)%n];
    var gx=Math.round((p[0]-GLON0)/CELL), gy=Math.round((p[1]-GLAT0)/CELL);
    pts.push(p);
    fix.push(juncMask&&gx>=0&&gy>=0&&gx<=GNX&&gy<=GNY ? juncMask[gy*W1+gx] : 0);
    var dx=q[0]-p[0], dy=q[1]-p[1];
    var steps=Math.round(Math.max(Math.abs(dx),Math.abs(dy))/CELL);
    for(k=1;k<steps;k++){ pts.push([p[0]+dx*k/steps, p[1]+dy*k/steps]); fix.push(0); }
  }
  return {p:pts, f:fix};
}
// 一趟对称低通: p ← p + f·((p₋+p₊)/2 − p)。Taubin 以 λ>0、μ<−λ 交替施行,
// 高频(格线锯齿)被压平而低频(疆域轮廓)几乎原样保留, 不像单纯的拉普拉斯
// 平滑那样越抹越瘦。钉住的交汇点不动 —— 三国共有的那个格点始终重合,
// 曲线自同一点散开, 三岔口不会被各自的平滑拉出小三角空洞。
function relaxRing(r,fix,f){
  var n=r.length, out=new Array(n);
  for(var i=0;i<n;i++){
    var b=r[i];
    if(fix[i]){ out[i]=b; continue; }
    var a=r[(i+n-1)%n], q=r[(i+1)%n];
    out[i]=[b[0]+f*((a[0]+q[0])*0.5-b[0]), b[1]+f*((a[1]+q[1])*0.5-b[1])];
  }
  return out;
}
// Chaikin 切角 (顶点式写法): 每个顶点让位给其两侧 1/4 处的点; 钉住的交汇点原样保留
function chaikinRing(r,fix){
  var n=r.length, out=[], of=[];
  for(var i=0;i<n;i++){
    var b=r[i];
    if(fix[i]){ out.push(b); of.push(1); continue; }
    var a=r[(i+n-1)%n], q=r[(i+1)%n];
    out.push([b[0]+0.25*(a[0]-b[0]), b[1]+0.25*(a[1]-b[1])]); of.push(0);
    out.push([b[0]+0.25*(q[0]-b[0]), b[1]+0.25*(q[1]-b[1])]); of.push(0);
  }
  return {p:out, f:of};
}
// Douglas-Peucker 抽稀 (在投影像素空间, 判据为顶点到弦的垂距)。
// 旧实现用"相邻三点叉积 < 常数"一趟并行剔点: 叉积随 Chaikin 细分逐级变小,
// 到第三、四次迭代整条曲线都低于阈值, 于是几乎所有点被同时删掉 —— 疆域被
// 削成几根直边、大幅缩水, 相邻两国各缩各的, 中间就裂出楔形空隙。这正是
// 图上"空洞、怪边、飘边"的主因。改用 DP 后每个顶点的偏差都有硬上限,
// 两国沿共享边界的偏差同为 ≤tol, 错开量 ≤2tol(≈0.1投影px), 肉眼与描边皆不可辨。
var DP_TOL=0.055;             // 投影 px
function dpSimplify(r,tol){
  var n=r.length;
  if(n<12) return r;
  var X=new Float64Array(n+1), Y=new Float64Array(n+1), i;
  for(i=0;i<n;i++){ X[i]=PX(r[i][0]); Y[i]=PY(r[i][1]); }
  X[n]=X[0]; Y[n]=Y[0];
  var far=0, bd=-1;
  for(i=1;i<n;i++){
    var dd=(X[i]-X[0])*(X[i]-X[0])+(Y[i]-Y[0])*(Y[i]-Y[0]);
    if(dd>bd){ bd=dd; far=i; }
  }
  var keep=new Uint8Array(n+1), t2=tol*tol, stack=[[0,far],[far,n]];
  keep[0]=1; keep[far]=1; keep[n]=1;
  while(stack.length){
    var seg=stack.pop(), s0=seg[0], s1=seg[1];
    if(s1<=s0+1) continue;
    var ax=X[s0], ay=Y[s0], bx=X[s1]-ax, by=Y[s1]-ay;
    var len=bx*bx+by*by, worst=-1, wi=-1;
    for(i=s0+1;i<s1;i++){
      var px=X[i]-ax, py=Y[i]-ay, d2;
      if(len<1e-18){ d2=px*px+py*py; }
      else {
        var u=(px*bx+py*by)/len;
        if(u<0)u=0; else if(u>1)u=1;
        var ex=px-u*bx, ey=py-u*by; d2=ex*ex+ey*ey;
      }
      if(d2>worst){ worst=d2; wi=i; }
    }
    if(worst>t2){ keep[wi]=1; stack.push([s0,wi],[wi,s1]); }
  }
  var out=[];
  for(i=0;i<n;i++) if(keep[i]) out.push(r[i]);
  return out.length>=6?out:r;
}
// 描迹 + 滤针尖小环 + 平滑: Chaikin 切角与 DP 抽稀交替, 既压住点数又控住误差
function traceSmooth(mask){
  var rings=traceMask(mask), keep=[], i;
  for(i=0;i<rings.length;i++)
    if(Math.abs(ringAreaPx(rings[i]))>=MINRING) keep.push(rings[i]);
  return keep.map(function(r){
    var d=densifyRing(r), pts=d.p, fix=d.f, s;
    for(s=0;s<TAUBIN_IT;s++) pts=relaxRing(pts, fix, s&1?TAU_M:TAU_L);
    for(s=0;s<CHAIKIN_IT;s++){ var c=chaikinRing(pts,fix); pts=c.p; fix=c.f; }
    return dpSimplify(pts,DP_TOL);
  });
}
// 8-连通分块 (在调用方给的 mask/lab 缓冲上就地做, 只走该国的格子)
function componentsOf(cells,mask,lab){
  var sizes=[], stack=[], i, k;
  for(i=0;i<cells.length;i++) lab[cells[i]]=-1;
  for(i=0;i<cells.length;i++){
    var c0=cells[i];
    if(lab[c0]>=0) continue;
    var id=sizes.length, cnt=0;
    lab[c0]=id; stack.length=0; stack.push(c0);
    while(stack.length){
      var sc=stack.pop(); cnt++;
      var sx=sc%GNX, sy=(sc-sx)/GNX;
      for(k=0;k<8;k++){
        var nx=sx+KX[k], ny=sy+KY[k];
        if(nx<0||ny<0||nx>=GNX||ny>=GNY) continue;
        var nc=ny*GNX+nx;
        if(mask[nc]&&lab[nc]<0){ lab[nc]=id; stack.push(nc); }
      }
    }
    sizes.push(cnt);
  }
  return sizes;
}

function refineItems(items){
  var N=GNX*GNY, n=items.length, i, j, c, k;
  // 1. 栅格化 + 面积/填充参数
  items.forEach(function(it){
    it.mask=new Uint8Array(N); it.cells=[];
    scanRings(it.raw,function(gx,gy){
      var cc=gy*GNX+gx;
      if(!it.mask[cc]){ it.mask[cc]=1; it.cells.push(cc); }
    });
    var a=0;
    it.raw.forEach(function(r){
      for(var x=0,y=r.length-1;x<r.length;y=x++) a+=r[y][0]*r[x][1]-r[x][0]*r[y][1];
    });
    it.area=Math.abs(a/2);
    it.fmax=it.p.tp==='p'?FILLP:FILLD;
  });
  // 2. 归属判定: 拉锯覆盖层最先画, 其余按面积从大到小 —— 后画的小国保住重叠区
  var owner=new Int16Array(N); owner.fill(-1);
  var order=[]; for(i=0;i<n;i++) order.push(i);
  order.sort(function(a,b){
    var fa=items[a].fr.ov?0:1, fb=items[b].fr.ov?0:1;
    return fa!==fb ? fa-fb : items[b].area-items[a].area;
  });
  order.forEach(function(ix){
    var cl=items[ix].cells;
    for(var q=0;q<cl.length;q++) owner[cl[q]]=ix;
  });
  var own2=new Int16Array(owner);
  // 3. 最近国场 (绕开他国, 跨海高代价)
  var F=ownerField(owner,OWNER_R), nd=F.d, no=F.o;
  // 4. 形态学闭运算: 先认出真正的"空白之地"(离所有政权都远的无主陆地),
  //    再把离空白之地足够远的无主陆地一律缝合给最近政权。窄廊、三国之间的
  //    楔形、国界与海岸之间的死角都在其中; 开阔草原与外邦保持无主。
  var openSeeds=[];
  for(c=0;c<N;c++) if(landMask[c]&&owner[c]<0&&nd[c]>CLOSE_R) openSeeds.push(c);
  var dOpen=landDist(openSeeds,CLOSE_R);
  for(c=0;c<N;c++){
    if(owner[c]>=0||!landMask[c]) continue;
    var oi=no[c];
    if(oi<0||nd[c]>items[oi].fmax) continue;
    if(dOpen[c]>CLOSE_R) own2[c]=oi;
  }
  // 5. 内袋填充: 完全被陆地围住(不触图边、不临海)的无主区块整块划归四邻,
  //    消除"国中空心"; 临海或通向图外的空白不动。
  var visited=new Uint8Array(N), stack=[];
  for(c=0;c<N;c++){
    if(visited[c]||!landMask[c]||own2[c]>=0) continue;
    var cells=[c], adjOwn=false, opened=false;
    visited[c]=1; stack.length=0; stack.push(c);
    while(stack.length){
      var cc=stack.pop();
      var sx=cc%GNX, sy=(cc-sx)/GNX;
      if(sx===0||sy===0||sx===GNX-1||sy===GNY-1) opened=true;
      for(k=0;k<4;k++){
        var tx=sx+KX[k], ty=sy+KY[k];
        if(tx<0||ty<0||tx>=GNX||ty>=GNY) continue;
        var tc=ty*GNX+tx;
        if(!landMask[tc]){ opened=true; continue; }   // 临海: 不算内袋
        if(own2[tc]>=0){ adjOwn=true; continue; }
        if(!visited[tc]){ visited[tc]=1; cells.push(tc); stack.push(tc); }
      }
    }
    if(opened||!adjOwn) continue;
    for(i=0;i<cells.length;i++){
      var pc=cells[i], po=no[pc];
      if(po<0){                                        // 超出最近国场: 取边界多数
        var bx=pc%GNX, by=(pc-bx)/GNX;
        for(k=0;k<8&&po<0;k++){
          var ux=bx+KX[k], uy=by+KY[k];
          if(ux<0||uy<0||ux>=GNX||uy>=GNY) continue;
          if(own2[uy*GNX+ux]>=0) po=own2[uy*GNX+ux];
        }
      }
      if(po>=0) own2[pc]=po;
    }
  }
  // 6. 多数表决平滑: 仅作用于填充所得/无主的陆地格 (原始疆界内的格子不动),
  //    抹平距离场等值线的锯齿、消除孤立小块; 只统计陆地邻格, 不侵蚀沿海窄条
  var cnt=new Int16Array(n+2), voters=[];
  for(c=0;c<N;c++)
    if(landMask[c]&&owner[c]<0&&nd[c]<=FILLD+20) voters.push(c);
  for(var pass=0;pass<2;pass++){
    var nxt=new Int16Array(own2);
    for(var vi=0;vi<voters.length;vi++){
      c=voters[vi];
      var mx=c%GNX, my=(c-mx)/GNX, k2;
      for(k2=0;k2<n+2;k2++) cnt[k2]=0;
      for(k2=0;k2<8;k2++){
        var qx=mx+KX[k2], qy=my+KY[k2];
        if(qx<0||qy<0||qx>=GNX||qy>=GNY) continue;
        var qc=qy*GNX+qx;
        if(!landMask[qc]) continue;
        cnt[own2[qc]+1]++;
      }
      var bl=own2[c], bc=4;
      for(k2=0;k2<n+1;k2++) if(cnt[k2]>bc){ bc=cnt[k2]; bl=k2-1; }
      if(bl!==own2[c]) nxt[c]=bl;
    }
    own2=nxt;
  }
  // 7. 掐点弥合: 某国只在 2×2 的对角上占两格时, 描迹会得到蝴蝶结式自交。
  //    能用无主陆地补一格就补(接通), 否则把对角格让给旁邻(断开)。
  for(var py=0;py<GNY-1;py++)for(var px=0;px<GNX-1;px++){
    var c00=py*GNX+px, c10=c00+1, c01=c00+GNX, c11=c01+1;
    var a=own2[c00], b=own2[c11], u=own2[c10], v=own2[c01];
    var A,ca,cb;
    if(a>=0&&a===b&&u!==a&&v!==a){ A=a; ca=c10; cb=c01; }
    else if(u>=0&&u===v&&a!==u&&b!==u){ A=u; ca=c00; cb=c11; }
    else continue;
    if(own2[ca]<0&&landMask[ca]) own2[ca]=A;
    else if(own2[cb]<0&&landMask[cb]) own2[cb]=A;
    else if(own2[ca]>=0) own2[cb]=own2[ca];
    else if(own2[cb]>=0) own2[ca]=own2[cb];
  }
  // 8. 碎块清理: 各国只保留成规模的连通块; 算法切出的碎屑并入接壤最长的邻国,
  //    孤悬海外的小岛(无陆邻)保留。
  var mtmp=new Uint8Array(N), lab=new Int32Array(N), finCells=[];
  for(i=0;i<n;i++) finCells.push([]);
  for(c=0;c<N;c++) if(own2[c]>=0) finCells[own2[c]].push(c);
  for(i=0;i<n;i++){
    var mine=finCells[i];
    if(!mine.length) continue;
    for(j=0;j<mine.length;j++) mtmp[mine[j]]=1;
    var sz=componentsOf(mine,mtmp,lab);
    for(j=0;j<mine.length;j++) mtmp[mine[j]]=0;
    if(sz.length<2) continue;
    var main=0; for(j=1;j<sz.length;j++) if(sz[j]>sz[main]) main=j;
    var share=[];                                   // 各碎块与各邻国的接壤格数
    for(j=0;j<sz.length;j++) share.push(null);
    for(var mi=0;mi<mine.length;mi++){
      c=mine[mi];
      var lb=lab[c];
      if(lb<0||lb===main||sz[lb]>=MINCOMP) continue;
      var fx=c%GNX, fy=(c-fx)/GNX;
      for(k=0;k<8;k++){
        var wx=fx+KX[k], wy=fy+KY[k];
        if(wx<0||wy<0||wx>=GNX||wy>=GNY) continue;
        var wo=own2[wy*GNX+wx];
        if(wo<0||wo===i) continue;
        if(!share[lb]) share[lb]={};
        share[lb][wo]=(share[lb][wo]||0)+1;
      }
    }
    var reassign={};
    for(j=0;j<sz.length;j++){
      if(j===main||sz[j]>=MINCOMP) continue;
      if(share[j]){
        var bestO=-1, bestC=-1;
        for(var ko in share[j]) if(share[j][ko]>bestC){ bestC=share[j][ko]; bestO=+ko; }
        reassign[j]=bestO;
      } else if(sz[j]<MINCELL) reassign[j]=-1;      // 无邻的针尖: 抹去
    }
    for(var ri=0;ri<mine.length;ri++){
      var mc=mine[ri], l3=lab[mc];
      if(l3<0||!reassign.hasOwnProperty(l3)) continue;
      own2[mc]=reassign[l3];
      if(reassign[l3]>=0) finCells[reassign[l3]].push(mc);   // 接收国的清单同步跟上
    }
  }
  // 9. 近岸外扩两格 (最终被陆地剪裁, 仅保证覆盖到真实海岸线/近岸小岛)
  for(var round=0;round<2;round++){
    var adds=[];
    for(var si=0;si<coastSea.length;si++){
      c=coastSea[si];
      if(own2[c]>=0) continue;
      var ex=c%GNX, ey=(c-ex)/GNX;
      for(k=0;k<8;k++){
        var gx2=ex+KX[k], gy2=ey+KY[k];
        if(gx2<0||gy2<0||gx2>=GNX||gy2>=GNY) continue;
        var o2=own2[gy2*GNX+gx2];
        if(o2>=0){ adds.push(c,o2); break; }
      }
    }
    for(i=0;i<adds.length;i+=2) own2[adds[i]]=adds[i+1];
  }
  // 10. 交汇点: 四邻格中出现三种以上归属(含无主)的格点, 平滑时钉住不动
  var W1=GNX+1;
  juncMask=new Uint8Array(W1*(GNY+1));
  for(var jy=0;jy<=GNY;jy++)for(var jx=0;jx<=GNX;jx++){
    var v0=(jx>0&&jy>0)?own2[(jy-1)*GNX+jx-1]:-2;
    var v1=(jx<GNX&&jy>0)?own2[(jy-1)*GNX+jx]:-2;
    var v2=(jx>0&&jy<GNY)?own2[jy*GNX+jx-1]:-2;
    var v3=(jx<GNX&&jy<GNY)?own2[jy*GNX+jx]:-2;
    var d3=1;
    if(v1!==v0) d3++;
    if(v2!==v0&&v2!==v1) d3++;
    if(v3!==v0&&v3!==v1&&v3!==v2) d3++;
    if(d3>=3) juncMask[jy*W1+jx]=1;
  }
  // 11. 每国描迹 + 平滑
  items.forEach(function(it){ it.fin=new Uint8Array(N); });
  for(c=0;c<N;c++) if(own2[c]>=0) items[own2[c]].fin[c]=1;
  items.forEach(function(it){
    var rings=traceSmooth(it.fin);
    it.rings=rings.length?rings
      :it.raw.map(function(r){ return r.map(function(p){ return [p[0],p[1]]; }); });
  });
  // 12. 标注锚点: 取各国"最深处"(到异属格距离最大的格)。形心在凹形或环形疆域中
  //     可能落到国外、或紧挨邻国而与邻国国号叠字; 最深处必在国内且离边界最远,
  //     其内切半径同时用来限制字号, 免得窄长疆域顶出一个撑破边界的大字。
  var idist=new Uint16Array(N), ibuckets=[], iseeds=[];
  idist.fill(0);
  for(c=0;c<N;c++){
    if(own2[c]<0) continue;
    var dx0=c%GNX, dy0=(c-dx0)/GNX, bnd=false;
    for(k=0;k<8&&!bnd;k++){
      var px2=dx0+KX[k], py2=dy0+KY[k];
      if(px2<0||py2<0||px2>=GNX||py2>=GNY){ bnd=true; break; }
      if(own2[py2*GNX+px2]!==own2[c]) bnd=true;
    }
    if(bnd){ idist[c]=0; iseeds.push(c); } else idist[c]=0xFFFF;
  }
  ibuckets[0]=iseeds;
  for(var idd=0;idd<4000;idd++){
    var iq=ibuckets[idd]; if(!iq) continue;
    for(var iqi=0;iqi<iq.length;iqi++){
      c=iq[iqi]; if(idist[c]!==idd) continue;
      var ix0=c%GNX, iy0=(c-ix0)/GNX;
      for(k=0;k<8;k++){
        var jx=ix0+KX[k], jy=iy0+KY[k];
        if(jx<0||jy<0||jx>=GNX||jy>=GNY) continue;
        var jc=jy*GNX+jx;
        if(own2[jc]<0) continue;
        var jv=idd+KC[k];
        if(jv<idist[jc]){ idist[jc]=jv; (ibuckets[jv]||(ibuckets[jv]=[])).push(jc); }
      }
    }
  }
  var cellPx=(CELL*SX)*(CELL*SY);
  items.forEach(function(it){ it.lab=null; it.labA=0; });
  for(c=0;c<N;c++){
    var lo2=own2[c]; if(lo2<0) continue;
    var itm=items[lo2]; itm.labA+=cellPx;
    if(!itm.lab||idist[c]>itm.labD){
      itm.labD=idist[c];
      itm.lab=[PX(GLON0+(c%GNX+0.5)*CELL), PY(GLAT0+((c-c%GNX)/GNX+0.5)*CELL)];
    }
  }
  items.forEach(function(it){
    if(it.lab){ it.labR=it.labD/10*CELL*SX; return; }
    // ov 覆盖层在归属判定中把格子全让给了他国, 无"最深处"可取 —— 退回原多边形形心
    var best=null;
    it.raw.forEach(function(r){
      var a2=0, cx2=0, cy2=0;
      for(var q=0,w=r.length-1;q<r.length;w=q++){
        var x1=PX(r[w][0]), y1=PY(r[w][1]), x2=PX(r[q][0]), y2=PY(r[q][1]);
        var cr2=x1*y2-x2*y1; a2+=cr2; cx2+=(x1+x2)*cr2; cy2+=(y1+y2)*cr2;
      }
      if(Math.abs(a2)<1e-9) return;
      var ar=Math.abs(a2/2);
      if(!best||ar>best[2]) best=[cx2/(3*a2), cy2/(3*a2), ar];
    });
    if(!best) return;
    it.lab=[best[0],best[1]]; it.labA=best[2]; it.labR=Math.sqrt(best[2])/1.7;
  });
  // 13. 拉锯/占领重叠区 (帧数据 ov:1 标记) → 斜纹层
  var stripes=[];
  for(i=0;i<n;i++)for(j=i+1;j<n;j++){
    if(!(items[i].fr.ov||items[j].fr.ov)) continue;
    var pm=null, num=0;
    var small=items[i].cells.length<items[j].cells.length?items[i]:items[j];
    var other=small===items[i]?items[j]:items[i];
    for(var sq=0;sq<small.cells.length;sq++){
      c=small.cells[sq];
      if(!other.mask[c]) continue;
      var oo=own2[c];
      if(!landMask[c]||oo===i||oo===j){ if(!pm)pm=new Uint8Array(N); pm[c]=1; num++; }
    }
    if(num>MINCELL){
      var rr=traceSmooth(pm);
      if(rr.length) stripes.push({a:i,b:j,rings:rr});
    }
  }
  return stripes;
}

/* ---------- 状态 ---------- */
var state={ t:1005, lo:T0, hi:T1, zoomStack:[], playing:false, speed:1, sel:null, vb:[0,0,W,H] };
var SVGNS='http://www.w3.org/2000/svg';
function el(n,attrs,parent){
  var e=document.createElementNS(SVGNS,n);
  for(var k in attrs) e.setAttribute(k,attrs[k]);
  if(parent) parent.appendChild(e);
  return e;
}
function div(cls,parent,html){
  var e=document.createElement('div'); if(cls)e.className=cls;
  if(html!==undefined)e.innerHTML=html; if(parent)parent.appendChild(e); return e;
}
function esc(s){ return String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;'); }

/* ---------- SVG 地图基础 ---------- */
var svg, defs, gBase, gPolity, gStripe, gBorder, gLabel, tooltip;
function buildMap(){
  var wrap=document.getElementById('map');
  svg=el('svg',{viewBox:'0 0 '+W+' '+H, id:'mapsvg'}); wrap.appendChild(svg);
  defs=el('defs',{},svg);
  // 海洋
  el('rect',{x:-2000,y:-2000,width:5000,height:5000,'class':'sea'},svg);
  // 陆地剪裁路径
  var clip=el('clipPath',{id:'landclip'},defs);
  var landD='';
  BASEMAP.land.forEach(function(r){ landD+=pathOf([r]); });
  el('path',{d:landD},clip);
  gBase=el('g',{},svg);
  el('path',{d:landD,'class':'land'},gBase);
  // 湖泊与河流
  BASEMAP.lakes.forEach(function(r){ el('path',{d:pathOf([r]),'class':'lake'},gBase); });
  BASEMAP.rivers.forEach(function(rv){
    var d=''; rv.p.forEach(function(p,i){ d+=(i?'L':'M')+PX(p[0]).toFixed(1)+' '+PY(p[1]).toFixed(1); });
    el('path',{d:d,'class':'river'},gBase);
  });
  gPolity=el('g',{'clip-path':'url(#landclip)',id:'gpolity'},svg);
  gStripe=el('g',{'clip-path':'url(#landclip)'},svg);
  gBorder=el('g',{'clip-path':'url(#landclip)',id:'gborder','class':'noptr'},svg);
  gLabel=el('g',{'class':'noptr'},svg);
  tooltip=div('tooltip',document.body); tooltip.style.display='none';
  initPanZoom(wrap);
}

/* ---------- 地图平移缩放 ---------- */
function applyVB(){ svg.setAttribute('viewBox',state.vb.join(' ')); }
function initPanZoom(wrap){
  var dragging=false,moved=false,px=0,py=0;
  wrap.addEventListener('pointerdown',function(e){
    if(e.target.closest('.panel,.card,.modal'))return;
    dragging=true;moved=false;px=e.clientX;py=e.clientY;
  });
  window.addEventListener('pointermove',function(e){
    if(!dragging)return;
    var dx=e.clientX-px, dy=e.clientY-py;
    if(Math.abs(dx)+Math.abs(dy)>4)moved=true;
    if(moved){
      var r=wrap.getBoundingClientRect();
      var k=state.vb[2]/r.width;
      state.vb[0]-=dx*k; state.vb[1]-=dy*k; applyVB();
      px=e.clientX;py=e.clientY;
    }
  });
  window.addEventListener('pointerup',function(){ dragging=false; setTimeout(function(){moved=false;},0); });
  wrap.addEventListener('wheel',function(e){
    e.preventDefault();
    var r=wrap.getBoundingClientRect();
    var mx=state.vb[0]+(e.clientX-r.left)/r.width*state.vb[2];
    var my=state.vb[1]+(e.clientY-r.top)/r.height*state.vb[3];
    var f=e.deltaY>0?1.18:1/1.18;
    var w=Math.min(Math.max(state.vb[2]*f,140),2600), h=w*H/W;
    state.vb=[mx-(mx-state.vb[0])*w/state.vb[2], my-(my-state.vb[1])*h/state.vb[3], w, h];
    applyVB();
  },{passive:false});
  wrap._movedRef=function(){return moved;};
}

/* ---------- 政权 活跃/边框 ---------- */
function frameAt(p,t){
  var fs=p.frames;
  for(var i=0;i<fs.length;i++) if(t>=fs[i].f && t<fs[i].t) return fs[i];
  return null;
}
function activeList(t){
  var out=[];
  POLITIES.forEach(function(p){
    if(t>=p.f && t<p.t){
      var fr=frameAt(p,t);
      if(fr) out.push({p:p,fr:fr});
    }
  });
  // 中原主线排前 (条纹绘制顺序: 先大后小)
  out.sort(function(a,b){
    var w=function(x){return x.p.tp==='c'?0:(x.p.tp==='s'?1:2);};
    return w(a)-w(b);
  });
  return out;
}

/* ---------- 渲染地图图层 ---------- */
var lastKey='';
function renderMap(){
  var act=activeList(state.t);
  var key=act.map(function(a){return a.p.id+'@'+a.fr.f;}).join('|');
  if(key===lastKey){ return act; }
  lastKey=key;
  gPolity.innerHTML=''; gStripe.innerHTML=''; gBorder.innerHTML=''; gLabel.innerHTML='';
  // 清理旧 pattern/clip
  Array.prototype.slice.call(defs.querySelectorAll('.dyn')).forEach(function(n){n.remove();});

  var items=act.map(function(a){
    return {p:a.p, fr:a.fr, raw:a.fr.ps};
  });
  var stripes=refineItems(items);
  items.forEach(function(it){ it.d=pathOf(it.rings); });
  // 填充 + 交互。色块与描边都不透明, 半透明交给整个图层 (CSS #gpolity{opacity})
  // —— 逐块半透明时相邻色块的同色描边会两两叠加, 每条国界都压出一道深色重影,
  // 三国交界处更结成斑点; 整层合成一次则无论怎么叠都只上一次色。
  items.forEach(function(it){
    var path=el('path',{d:it.d,fill:it.p.c,stroke:it.p.c,'stroke-width':1.1,'stroke-linejoin':'round','class':'polity'},gPolity);
    path.addEventListener('pointerenter',function(e){ showTip(it.p,e); });
    path.addEventListener('pointermove',function(e){ moveTip(e); });
    path.addEventListener('pointerleave',function(){ hideTip(); });
    path.addEventListener('click',function(e){
      if(document.getElementById('map')._movedRef()) return;
      e.stopPropagation(); hideTip(); openCard(it.p);
    });
    el('path',{d:it.d,'class':'polity-border'},gBorder);
  });
  // 拉锯/占领重叠区条纹 (仅数据 ov:1 标记的政权参与)
  stripes.forEach(function(s){
    var A=items[s.a], B=items[s.b];
    var pid='pat_'+A.p.id+'_'+B.p.id;
    var pat=el('pattern',{id:pid,'class':'dyn',width:14,height:14,patternUnits:'userSpaceOnUse',patternTransform:'rotate(45)'},defs);
    el('rect',{x:0,y:0,width:7,height:14,fill:A.p.c},pat);
    el('rect',{x:7,y:0,width:7,height:14,fill:B.p.c},pat);
    el('path',{d:pathOf(s.rings),fill:'url(#'+pid+')','fill-opacity':0.96,'class':'noptr'},gStripe);
  });
  // 标签: 落在疆域"最深处"(见 refineItems 第12步), 字号同时受面积与内切半径约束
  items.forEach(function(it){
    if(!it.lab) return;
    var fs=Math.max(10,Math.min(46,Math.sqrt(it.labA)/3.2,it.labR*1.7));
    var t=el('text',{x:it.lab[0],y:it.lab[1],'class':'plabel','font-size':fs},gLabel);
    t.textContent=it.p.abbr;
    if(fs>17 && it.p.n!==it.p.abbr){
      var t2=el('text',{x:it.lab[0],y:it.lab[1]+fs*0.78,'class':'plabel sub','font-size':Math.max(9,fs*0.3)},gLabel);
      t2.textContent=it.p.n;
    }
  });
  return act;
}

/* ---------- 提示框 ---------- */
function showTip(p,e){
  tooltip.innerHTML='<b>'+esc(p.n)+'</b><span>'+fmtRange(p.f,p.t)+' · 存续'+durText(p.f,p.t)+'</span><i>点击查看详情</i>';
  tooltip.style.display='block'; moveTip(e);
}
function moveTip(e){ tooltip.style.left=(e.clientX+14)+'px'; tooltip.style.top=(e.clientY+14)+'px'; }
function hideTip(){ tooltip.style.display='none'; }

/* ---------- 政权详情卡 ---------- */
function openCard(p){
  state.sel=p.id;
  var c=document.getElementById('card');
  var pop=(p.pop||[]).map(function(x){
    return '<tr><td>'+fmtY(x[0])+'</td><td>'+esc(x[1])+'</td></tr>';
  }).join('');
  var srcs=(p.srcs||[]).map(function(id){
    var s=SOURCES.find(function(s){return s.id===id;});
    return s?'<li>'+esc(s.zh)+'</li>':'';
  }).join('');
  c.innerHTML=
    '<div class="card-head" style="border-color:'+p.c+'">'+
      '<span class="chip" style="background:'+p.c+'">'+esc(p.abbr)+'</span>'+
      '<div><h2>'+esc(p.n)+'</h2><p>'+fmtRange(p.f,p.t)+' · 存续'+durText(p.f,p.t)+'</p></div>'+
      '<button class="x" id="cardx">✕</button></div>'+
    '<div class="card-body">'+
      '<dl>'+
      '<dt>都城</dt><dd>'+esc(p.cap||'—')+'</dd>'+
      '<dt>开创</dt><dd>'+esc(p.fdr||'—')+'</dd>'+
      '<dt>结局</dt><dd>'+esc(p.lr||'—')+'</dd>'+
      '</dl>'+
      (pop?'<h3>人口</h3><table class="pop">'+pop+'</table>':'')+
      (p.note?'<h3>概述</h3><p class="note">'+esc(p.note)+'</p>':'')+
      (srcs?'<h3>本条主要来源</h3><ul class="srcs">'+srcs+'</ul>':'')+
      '<button class="linkbtn" onclick="document.getElementById(\'srcbtn\').click()">查看全部来源与精度说明 →</button>'+
    '</div>';
  c.style.display='flex';
  document.getElementById('cardx').onclick=closeCard;
}
function closeCard(){ document.getElementById('card').style.display='none'; state.sel=null; }

/* ---------- 浮动面板 (帝王 / 政权) ---------- */
var panelTab='emp';
function buildPanel(){
  var p=document.getElementById('panel');
  p.innerHTML='<div class="phead" id="phead"><span class="grip">⣿</span>'+
    '<div class="tabs"><button id="tab-emp" class="on">帝王</button><button id="tab-dyn">政权</button></div>'+
    '<button class="mini" id="pfold">—</button></div>'+
    '<div class="pbody" id="pbody"></div>';
  document.getElementById('tab-emp').onclick=function(){setTab('emp');};
  document.getElementById('tab-dyn').onclick=function(){setTab('dyn');};
  var folded=false;
  document.getElementById('pfold').onclick=function(){
    folded=!folded;
    document.getElementById('pbody').style.display=folded?'none':'block';
    this.textContent=folded?'+':'—';
  };
  // 拖动
  var head=document.getElementById('phead'), sx=0,sy=0,ox=0,oy=0,drag=false;
  head.addEventListener('pointerdown',function(e){
    if(e.target.tagName==='BUTTON')return;
    drag=true; sx=e.clientX; sy=e.clientY;
    var r=p.getBoundingClientRect(); ox=r.left; oy=r.top;
    head.setPointerCapture(e.pointerId);
  });
  head.addEventListener('pointermove',function(e){
    if(!drag)return;
    var x=Math.min(window.innerWidth-120,Math.max(4,ox+e.clientX-sx));
    var y=Math.min(window.innerHeight-80,Math.max(4,oy+e.clientY-sy));
    p.style.left=x+'px'; p.style.top=y+'px'; p.style.right='auto';
  });
  head.addEventListener('pointerup',function(){drag=false;});
}
function setTab(t){
  panelTab=t;
  document.getElementById('tab-emp').className=t==='emp'?'on':'';
  document.getElementById('tab-dyn').className=t==='dyn'?'on':'';
  renderPanel(true);
}
function eraAt(emp,t){
  if(!emp.e||!emp.e.length)return null;
  var cur=null;
  emp.e.forEach(function(x){ if(t>=x[1])cur=x; });
  return cur;
}
function avatarSVG(emp,color){
  var ch=emp.n.replace(/[·(].*$/,''); ch=ch.charAt(ch.length-1);
  return '<svg viewBox="0 0 44 44"><circle cx="22" cy="22" r="20" fill="'+color+'"/>'+
    '<circle cx="22" cy="22" r="20" fill="none" stroke="rgba(255,255,255,.55)" stroke-width="1.6"/>'+
    '<text x="22" y="29" text-anchor="middle" font-size="20" fill="#fff" font-family="Songti SC,STSong,serif" font-weight="700">'+esc(ch)+'</text></svg>';
}
var lastPanelKey='';
function renderPanel(force){
  var act=activeList(state.t);
  var body=document.getElementById('pbody');
  if(panelTab==='emp'){
    var ids={}; act.forEach(function(a){ids[a.p.id]=a.p;});
    var rows=[];
    EMPERORS.forEach(function(emp,idx){
      if(state.t>=emp.rf && state.t<emp.rt && ids[emp.y]) rows.push({e:emp,i:idx,p:ids[emp.y]});
    });
    var key='e'+rows.map(function(r){return r.i;}).join(',')+'~'+Math.round(state.t*12);
    if(!force && key===lastPanelKey)return; lastPanelKey=key;
    if(!rows.length){ body.innerHTML='<p class="empty">此刻无在位君主记录<br><small>(史前时代、现代或数据未及之政权)</small></p>'; return; }
    body.innerHTML=rows.map(function(r){
      var e=r.e, era=eraAt(e,state.t);
      var pred=null,succ=null;
      for(var i=r.i-1;i>=0;i--) if(EMPERORS[i].y===e.y){pred=EMPERORS[i];break;}
      for(var j=r.i+1;j<EMPERORS.length;j++) if(EMPERORS[j].y===e.y){succ=EMPERORS[j];break;}
      var age=e.b!=null?('<b>'+Math.max(0,Math.floor(state.t-e.b))+'岁</b>'):'生年不详';
      var life=(e.b!=null?fmtY(yearOf(e.b)):'?')+' — '+(e.d!=null?fmtY(yearOf(e.d)):'?');
      var reignYrs=state.t-e.rf;
      var reignTxt=reignYrs<1?('在位第'+Math.max(1,Math.ceil(reignYrs*365))+'天'):('在位第'+Math.ceil(reignYrs)+'年');
      return '<div class="emp">'+
        '<div class="eav">'+avatarSVG(e,r.p.c)+'</div>'+
        '<div class="einfo">'+
          '<div class="el1"><b>'+esc(e.t)+'</b><span class="dyntag" style="background:'+r.p.c+'">'+esc(r.p.abbr)+'</span></div>'+
          '<div class="el2">名讳 '+esc(e.n)+(e.tm?' · 庙号'+esc(e.tm):'')+(e.sh?' · 谥'+esc(e.sh):'')+'</div>'+
          '<div class="el2">'+(era?'年号 <b>'+esc(era[0])+'</b>('+Math.max(1,Math.ceil(state.t-era[1]))+'年) · ':'')+reignTxt+'</div>'+
          '<div class="el2">'+life+' · 现年'+age+'</div>'+
          '<div class="el3">'+(pred?'← '+esc(pred.t):'← 开国')+' &nbsp; '+(succ?esc(succ.t)+' →':'末代 →')+'</div>'+
          (e.note?'<div class="enote">'+esc(e.note)+'</div>':'')+
        '</div></div>';
    }).join('');
  } else {
    var key2='d'+act.map(function(a){return a.p.id;}).join(',')+'~'+Math.round(state.t*4);
    if(!force && key2===lastPanelKey)return; lastPanelKey=key2;
    if(!act.length){ body.innerHTML='<p class="empty">此刻无政权记录</p>'; return; }
    body.innerHTML=act.map(function(a){
      var p=a.p;
      var frac=Math.min(1,Math.max(0,(state.t-p.f)/(p.t-p.f)));
      var leftPct=Math.round((1-frac)*100);
      return '<div class="dyn-row" data-id="'+p.id+'">'+
        '<span class="chip" style="background:'+p.c+'">'+esc(p.abbr)+'</span>'+
        '<div class="dinfo"><div class="dl1"><b>'+esc(p.n)+'</b><span>'+fmtY(yearOf(p.f))+' — '+fmtY(yearOf(p.t))+'</span></div>'+
        '<div class="lifebar"><div class="lifefill" style="width:'+(frac*100).toFixed(1)+'%;background:'+p.c+'"></div><div class="lifedot" style="left:'+(frac*100).toFixed(1)+'%"></div></div>'+
        '<div class="dl2">已历'+durText(p.f,state.t)+' · 国祚余'+leftPct+'%</div></div></div>';
    }).join('');
    Array.prototype.forEach.call(body.querySelectorAll('.dyn-row'),function(row){
      row.onclick=function(){
        var p=POLITIES.find(function(x){return x.id===row.dataset.id;});
        if(p)openCard(p);
      };
    });
  }
}

/* ---------- 时间轴 ---------- */
var ANCH=[[-8000,0],[-2070,0.10],[-770,0.24],[-221,0.36],[220,0.46],[907,0.60],[1368,0.775],[1912,0.92],[2026.5,1]];
function isFull(){ return state.lo===T0 && state.hi===T1; }
function valToPos(v){
  if(!isFull()) return (v-state.lo)/(state.hi-state.lo);
  for(var i=0;i<ANCH.length-1;i++){
    if(v<=ANCH[i+1][0]||i===ANCH.length-2){
      var a=ANCH[i],b=ANCH[i+1];
      return a[1]+(v-a[0])/(b[0]-a[0])*(b[1]-a[1]);
    }
  }
  return 1;
}
function posToVal(f){
  f=Math.min(1,Math.max(0,f));
  if(!isFull()) return state.lo+f*(state.hi-state.lo);
  for(var i=0;i<ANCH.length-1;i++){
    if(f<=ANCH[i+1][1]||i===ANCH.length-2){
      var a=ANCH[i],b=ANCH[i+1];
      return a[0]+(f-a[1])/(b[1]-a[1])*(b[0]-a[0]);
    }
  }
  return T1;
}
function tickStep(span){
  if(span>4000)return 1000; if(span>1600)return 500; if(span>700)return 200;
  if(span>280)return 100; if(span>130)return 50; if(span>55)return 20;
  if(span>26)return 10; if(span>11)return 5; if(span>4.5)return 2;
  if(span>2.2)return 1; if(span>0.45)return 1/12; return 1/365;
}
var tlCanvas, tlThumb, tlWrap;
function drawTimeline(){
  var r=tlWrap.getBoundingClientRect();
  var dpr=window.devicePixelRatio||1;
  tlCanvas.width=r.width*dpr; tlCanvas.height=54*dpr;
  tlCanvas.style.width=r.width+'px'; tlCanvas.style.height='54px';
  var ctx=tlCanvas.getContext('2d'); ctx.scale(dpr,dpr);
  ctx.clearRect(0,0,r.width,54);
  var span=state.hi-state.lo;
  // 时期底色带 (全览时)
  if(isFull()){
    var bands=[[-8000,-2070,'#3a3427','史前'],[-2070,-770,'#4a3b22','夏商周'],[-770,-221,'#3d3040','春秋战国'],[-221,589,'#31404d','秦汉魏晋南北朝'],[589,979,'#4d4327','隋唐五代'],[979,1279,'#4d2b2b','宋辽金'],[1279,1644,'#2b3d4d','元明'],[1644,1912,'#4a3f20','清'],[1912,1949.75,'#28405c','民国'],[1949.75,2026.5,'#5c2a2a','共和国']];
    bands.forEach(function(b){
      var x0=valToPos(b[0])*r.width, x1=valToPos(b[1])*r.width;
      ctx.fillStyle=b[2]; ctx.fillRect(x0,26,x1-x0,14);
      if(x1-x0>34){ ctx.fillStyle='rgba(255,240,210,.75)'; ctx.font='10px sans-serif'; ctx.textAlign='center'; ctx.fillText(b[3],(x0+x1)/2,36.5); }
    });
  } else {
    ctx.fillStyle='rgba(160,140,90,.18)'; ctx.fillRect(0,26,r.width,14);
  }
  // 刻度
  var step=tickStep(span);
  var v0=Math.ceil(state.lo/step)*step;
  ctx.strokeStyle='rgba(220,200,150,.5)'; ctx.fillStyle='rgba(235,220,180,.9)';
  ctx.font='10px sans-serif'; ctx.textAlign='center';
  var lastX=-100;
  for(var v=v0;v<=state.hi+1e-9;v+=step){
    var x=valToPos(v)*r.width;
    ctx.beginPath(); ctx.moveTo(x,18); ctx.lineTo(x,26); ctx.stroke();
    if(x-lastX>42){
      var lab;
      if(step>=1) lab=(v<=0?'前'+Math.round(-v):Math.round(v));
      else if(step>=1/12-1e-9){ var o=ymd(v+1e-6); lab=o.m+'月'; if(o.m===1)lab=fmtY(o.y); }
      else { var o2=ymd(v+1e-6); lab=o2.m+'/'+o2.d; }
      ctx.fillText(String(lab),x,14); lastX=x;
    }
  }
  // 缩放窗口指示与按钮状态
  document.getElementById('tl-range').textContent=
    isFull() ? '' : fmtDate(state.lo,span)+' ~ '+fmtDate(state.hi,span);
  document.getElementById('tl-in').disabled=span<=0.03;
  document.getElementById('tl-out').disabled=isFull();
  document.getElementById('tl-reset').disabled=isFull();
  positionThumb();
  updateHeader();
}
function positionThumb(){
  var r=tlWrap.getBoundingClientRect();
  tlThumb.style.left=(valToPos(state.t)*r.width)+'px';
}
function setT(t,skipMap){
  state.t=Math.min(T1-0.0001,Math.max(T0,t));
  positionThumb();
  updateHeader();
  if(!skipMap){ renderMap(); renderPanel(); }
  // 若详情卡的政权已消亡则关闭
  if(state.sel){
    var p=POLITIES.find(function(x){return x.id===state.sel;});
    if(p&&(state.t<p.f||state.t>=p.t)) closeCard();
  }
}
function zoomTimeline(center){
  var span=state.hi-state.lo;
  if(span<=0.03) return false;
  var ns=Math.max(0.03, span/6);
  // 全览首次缩放取800年窗口以获得舒适密度
  if(isFull()) ns=800;
  var lo=center-ns/2, hi=center+ns/2;
  if(lo<T0){lo=T0;hi=T0+ns;} if(hi>T1){hi=T1;lo=T1-ns;}
  state.zoomStack.push([state.lo,state.hi]);
  state.lo=lo; state.hi=hi;
  drawTimeline();
  flashZoom();
  return true;
}
function resetZoom(){
  state.zoomStack=[]; state.lo=T0; state.hi=T1; drawTimeline();
}
function zoomOutOnce(){
  var prev=state.zoomStack.pop();
  if(prev){ state.lo=prev[0]; state.hi=prev[1]; } else { state.lo=T0; state.hi=T1; }
  drawTimeline();
}
function flashZoom(){
  tlWrap.classList.add('zooming');
  setTimeout(function(){tlWrap.classList.remove('zooming');},350);
}
function initTimeline(){
  tlWrap=document.getElementById('tl-track');
  tlCanvas=document.getElementById('tl-canvas');
  tlThumb=document.getElementById('tl-thumb');
  var isDown=false;
  function evPos(e){
    var r=tlWrap.getBoundingClientRect();
    return (e.clientX-r.left)/r.width;
  }
  tlWrap.addEventListener('pointerdown',function(e){
    isDown=true;
    tlWrap.setPointerCapture(e.pointerId);
    setT(posToVal(evPos(e)));
  });
  tlWrap.addEventListener('pointermove',function(e){
    if(!isDown)return;
    setT(posToVal(evPos(e)));
  });
  function up(){ isDown=false; }
  tlWrap.addEventListener('pointerup',up);
  tlWrap.addEventListener('pointercancel',up);
  document.getElementById('tl-in').onclick=function(){ zoomTimeline(state.t); };
  document.getElementById('tl-reset').onclick=resetZoom;
  document.getElementById('tl-out').onclick=zoomOutOnce;
  window.addEventListener('resize',drawTimeline);
  window.addEventListener('keydown',function(e){
    if(e.target.tagName==='INPUT')return;
    var span=state.hi-state.lo;
    if(e.key==='ArrowLeft'){ setT(state.t-span/400); e.preventDefault(); }
    if(e.key==='ArrowRight'){ setT(state.t+span/400); e.preventDefault(); }
    if(e.key===' '){ togglePlay(); e.preventDefault(); }
  });
}

/* ---------- 播放 ---------- */
var rafId=null,lastTs=0;
function togglePlay(){
  state.playing=!state.playing;
  document.getElementById('playbtn').textContent=state.playing?'⏸':'▶';
  if(state.playing){ lastTs=0; rafId=requestAnimationFrame(tick); }
  else if(rafId) cancelAnimationFrame(rafId);
}
function tick(ts){
  if(!state.playing)return;
  if(lastTs){
    var dt=(ts-lastTs)/1000;
    var span=state.hi-state.lo;
    var rate=isFull()? 40 : span/18;   // 年/秒
    var nt=state.t+dt*rate*state.speed;
    if(nt>=T1-0.001){ nt=T1-0.001; togglePlay(); }
    setT(nt);
  }
  lastTs=ts;
  rafId=requestAnimationFrame(tick);
}

/* ---------- 顶栏 ---------- */
function updateHeader(){
  var span=state.hi-state.lo;
  document.getElementById('bigdate').textContent=fmtDate(state.t,span);
  var act=activeList(state.t);
  var main=act.filter(function(a){return a.p.tp==='c';}).map(function(a){return a.p.n;});
  var era=document.getElementById('eraline');
  era.textContent = main.length? main.join(' · ') : (act.length?act[0].p.n+' 等':'—');
}

/* ---------- 来源弹窗 ---------- */
function buildSources(){
  var m=document.getElementById('modal');
  var list=SOURCES.map(function(s){
    return '<li><b>'+esc(s.zh)+'</b><p>'+esc(s.detail)+'</p>'+(s.url?'<a href="'+s.url+'" target="_blank" rel="noopener">'+esc(s.url)+'</a>':'')+'</li>';
  }).join('');
  var notes=SOURCE_NOTES.map(function(n){return '<li>'+esc(n)+'</li>';}).join('');
  m.innerHTML='<div class="mbox"><div class="mhead"><h2>数据来源与精度说明</h2><button class="x" id="mx">✕</button></div>'+
    '<div class="mbody"><h3>⚠ 精度与取舍说明</h3><ul class="notes">'+notes+'</ul>'+
    '<h3>主要文献与数据集</h3><ul class="srclist">'+list+'</ul></div></div>';
  m.querySelector('#mx').onclick=function(){m.style.display='none';};
  m.addEventListener('click',function(e){ if(e.target===m)m.style.display='none'; });
  document.getElementById('srcbtn').onclick=function(){ m.style.display='flex'; };
  var h=document.getElementById('helpmodal');
  h.querySelector('#hx').onclick=function(){h.style.display='none';};
  h.addEventListener('click',function(e){ if(e.target===h)h.style.display='none'; });
  document.getElementById('helpbtn').onclick=function(){ h.style.display='flex'; };
}

/* ---------- 启动 ---------- */
function init(){
  buildLandGrid();
  buildMap();
  buildPanel();
  buildSources();
  initTimeline();
  document.getElementById('playbtn').onclick=togglePlay;
  document.getElementById('speed').onchange=function(){ state.speed=parseFloat(this.value); };
  document.getElementById('map').addEventListener('click',function(e){
    if(e.target.tagName!=='path'||!e.target.classList.contains('polity')) closeCard();
  });
  drawTimeline();
  var h=parseFloat((location.hash||'').replace(/^#/,''));
  setT(isFinite(h)?h:1005);   // 默认: 澶渊之盟之年 —— 宋辽夏并立, 画面最丰富; 可用 #年份 直达
  renderPanel(true);
}
if(document.readyState==='loading') document.addEventListener('DOMContentLoaded',init);
else init();
})();
