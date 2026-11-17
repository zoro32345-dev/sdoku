/* 스도쿠왕 쟁탈전 (동시 대결) — 선생님·학생 화면이 함께 쓰는 코드 */

/* ===== Supabase 연결 =====
   아래 열쇠는 "공개용"이라 화면 코드에 있어도 괜찮다.
   학생 쪽에서 할 수 있는 일은 데이터베이스 규칙과 함수가 막고 있다(supabase/*.sql). */
const SB_URL = 'https://yhfvvsenuqnfdtcjlnbz.supabase.co';
const SB_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InloZnZ2c2VudXFuZmR0Y2psbmJ6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTMwNDY5MzMsImV4cCI6MjEwODYyMjkzM30.PNU720EekIf_uR6NAUgi-F2wzVmtHKj6M3fnxdlfDHI';
const sb = window.supabase.createClient(SB_URL, SB_KEY, { auth: { persistSession: false } });

const $ = id => document.getElementById(id);
const esc = s => String(s).replace(/[&<>"]/g, ch => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[ch]));
const nm = p => `${p+1}번`;

async function call(fn, args){
  const { data, error } = await sb.rpc(fn, args);
  if(error) throw error;
  return data;
}

/* ===== 색 ===== */
const BASIC = [
  {main:'#e5484d', tint:'#fbd5d5', base:'#f29a9c'},
  {main:'#3b82f6', tint:'#d3e3fd', base:'#93b8f7'},
  {main:'#16a34a', tint:'#cdeed8', base:'#86cf9f'},
  {main:'#f59e0b', tint:'#fde6bd', base:'#f7c562'},
];
function makeColors(n){
  if(n<=4) return BASIC.slice(0,n);
  return Array.from({length:n},(_,p)=>{
    const h = Math.round((p*137.508 + 8) % 360);
    const l = p%2 ? 38 : 46;
    return {main:`hsl(${h} 70% ${l}%)`, tint:`hsl(${h} 80% 89%)`, base:`hsl(${h} 70% 73%)`};
  });
}
const dotHtml = (colors,p) => `<span class="dot" style="background:${colors[p].main}"></span>`;

/* ===== 지도와 문제 만들기 (선생님 기기에서) ===== */
const KEEP = {easy:0.45, normal:0.32, hard:0.2};
const blocksFor = n => { let k=1; while((3*k)*(3*k) < 2*n) k++; return k; };

function candMask(g, i){
  const r=Math.floor(i/9), c=i%9; let used = 0;
  for(let k=0;k<9;k++){ used |= 1<<g[r*9+k]; used |= 1<<g[k*9+c]; }
  const br=r-r%3, bc=c-c%3;
  for(let a=0;a<3;a++) for(let b=0;b<3;b++) used |= 1<<g[(br+a)*9+bc+b];
  return (~used) & 0x3FE;
}
function shuffle(a){ for(let i=a.length-1;i>0;i--){ const j=Math.floor(Math.random()*(i+1)); [a[i],a[j]]=[a[j],a[i]]; } return a; }
function fillFull(g){
  const i = g.indexOf(0); if(i<0) return true;
  const m = candMask(g,i);
  for(const d of shuffle([1,2,3,4,5,6,7,8,9])){ if(m & (1<<d)){ g[i]=d; if(fillFull(g)) return true; } }
  g[i]=0; return false;
}
function countSol(g){
  let best=-1, bestM=0, bestCnt=10;
  for(let i=0;i<81;i++){
    if(g[i]) continue;
    const m = candMask(g,i); let cnt=0;
    for(let d=1;d<=9;d++) if(m&(1<<d)) cnt++;
    if(cnt===0) return 0;
    if(cnt<bestCnt){ best=i; bestM=m; bestCnt=cnt; if(cnt===1) break; }
  }
  if(best<0) return 1;
  let total=0;
  for(let d=1;d<=9;d++){ if(bestM&(1<<d)){ g[best]=d; total+=countSol(g); if(total>=2) break; } }
  g[best]=0; return total;
}
function makePuzzle(keepLocal, diff){
  const sol = new Array(81).fill(0); fillFull(sol);
  const g = sol.slice();
  const others = shuffle([...Array(81).keys()].filter(i=>!keepLocal[i]));
  const target = Math.round(others.length*KEEP[diff]);
  let shown = others.length;
  for(const i of others){
    if(shown <= target) break;
    const t=g[i]; g[i]=0;
    if(countSol(g.slice())===1) shown--; else g[i]=t;
  }
  return {sol, puz:g};
}
function placeBases(n, B){
  const cands = [];
  for(let by=0;by<B;by++) for(let bx=0;bx<B;bx++) if((bx+by)%2===0) cands.push([bx,by]);
  const chosen=[cands[0]], used=new Set([0]);
  const dist=(a,b)=>Math.abs(a[0]-b[0])+Math.abs(a[1]-b[1]);
  while(chosen.length<n){
    let best=-1, bestD=-1, bestSum=-1;
    cands.forEach((c,ci)=>{
      if(used.has(ci)) return;
      let md=1e9, sum=0; for(const s of chosen){ const d=dist(c,s); md=Math.min(md,d); sum+=d; }
      if(md>bestD || (md===bestD && sum>bestSum)){ best=ci; bestD=md; bestSum=sum; }
    });
    used.add(best); chosen.push(cands[best]);
  }
  return chosen.sort((a,b)=>a[1]-b[1] || a[0]-b[0]);
}
// 인원·난이도로 지도 전체를 만든다. 결과는 데이터베이스에 그대로 보낸다.
function buildMap(n, diff){
  const K=blocksFor(n), B=3*K, W=9*K, C=W*W;
  const bases = placeBases(n, B);
  const owner = new Array(C).fill(-1), base = new Array(C).fill(false), dist = new Array(C).fill(0);
  bases.forEach(([bx,by],p)=>{ for(let a=0;a<3;a++) for(let b=0;b<3;b++){ const i=(by*3+a)*W + bx*3+b; owner[i]=p; base[i]=true; } });
  const REACH = 2;
  for(let i=0;i<C;i++){
    if(base[i]) continue;
    const r=Math.floor(i/W), c=i%W; let best=1e9, who=-1;
    bases.forEach(([bx,by],p)=>{
      const r0=by*3, c0=bx*3;
      const d = Math.max(0,r0-r,r-(r0+2)) + Math.max(0,c0-c,c-(c0+2));
      if(d<best){ best=d; who=p; } else if(d===best) who=-1;
    });
    owner[i] = best<=REACH ? who : -1; dist[i]=best;
  }
  // 모두 같은 칸 수로 시작
  const mine = Array.from({length:n},()=>[]);
  for(let i=0;i<C;i++) if(owner[i]>=0 && !base[i]) mine[owner[i]].push(i);
  const fair = Math.min(...mine.map(a=>a.length));
  mine.forEach(list=>{ shuffle(list).sort((a,b)=>dist[b]-dist[a]); list.slice(0, list.length-fair).forEach(i=>owner[i]=-1); });

  const sol=new Array(C), puzzle=new Array(C);
  for(let BY=0;BY<K;BY++) for(let BX=0;BX<K;BX++){
    const g2l = (r,c)=>(BY*9+r)*W + BX*9+c;
    const keep = Array.from({length:81},(_,j)=>base[g2l(Math.floor(j/9), j%9)]);
    const {sol:s, puz} = makePuzzle(keep, diff);
    for(let j=0;j<81;j++){ const i=g2l(Math.floor(j/9), j%9); sol[i]=s[j]; puzzle[i]=puz[j]; }
  }
  return {n, K, W, C, sol, puzzle, owner, base};
}

/* ===== 방 정보 → 화면 상태 ===== */
// room: sudoku_rooms 한 줄. claims: sudoku_claims 여러 줄
function makeView(room){
  const W=room.k*9, C=W*W;
  const v = {
    room, n:room.n, K:room.k, W, C,
    colors: makeColors(room.n),
    owner: room.init_owner.slice(),
    value: room.puzzle.slice(),
    given: room.puzzle.map(x=>x>0),
    base: room.base,
    claimed: new Set(),
    tagAt: new Map(),
  };
  // 본진 3×3의 왼쪽 위 칸에 번호표
  for(let i=0;i<C;i++){
    const r=Math.floor(i/W), c=i%W;
    if(v.base[i] && r%3===0 && c%3===0) v.tagAt.set(i, v.owner[i]);
  }
  return v;
}
function applyClaim(v, cl){
  if(v.claimed.has(cl.cell)) return false;
  v.claimed.add(cl.cell); v.owner[cl.cell]=cl.player; v.value[cl.cell]=cl.value;
  return true;
}
const isBlank = (v,i) => v.value[i]===0;
const blanksLeft = v => v.value.filter(x=>x===0).length;
function countsOf(v){ const c=new Array(v.n).fill(0); v.owner.forEach(o=>{ if(o>=0) c[o]++; }); return c; }
function neighborsOf(v,i){ const W=v.W, r=Math.floor(i/W), c=i%W, o=[]; if(r>0)o.push(i-W); if(r<W-1)o.push(i+W); if(c>0)o.push(i-1); if(c<W-1)o.push(i+1); return o; }
function legalFor(v,p,i){
  if(!isBlank(v,i)) return false;
  if(v.owner[i]===p) return true;
  return neighborsOf(v,i).some(j=>v.owner[j]===p);
}

/* ===== 판 그리기 ===== */
function buildBoard(el, v, onCell){
  const W=v.W; el.innerHTML='';
  el.style.gridTemplateColumns = `repeat(${W},1fr)`;
  el.style.setProperty('--k', v.K);
  el.style.setProperty('--bw', v.K===1 ? '3px' : '2px');
  const frag = document.createDocumentFragment();
  for(let i=0;i<v.C;i++){
    const d=document.createElement('div'), r=Math.floor(i/W), c=i%W;
    d.className='cell';
    if(c<W-1){ if(c%9===8) d.classList.add('br9'); else if(c%3===2) d.classList.add('br'); } else d.style.borderRight='none';
    if(r<W-1){ if(r%9===8) d.classList.add('bb9'); else if(r%3===2) d.classList.add('bb'); } else d.style.borderBottom='none';
    d.innerHTML = '<span class="v"></span>';
    if(v.tagAt.has(i)){ const p=v.tagAt.get(i); d.insertAdjacentHTML('beforeend', `<span class="tag" style="--pc:${v.colors[p].main}">${p+1}</span>`); }
    if(onCell) d.onclick = ()=>onCell(i);
    frag.appendChild(d);
  }
  el.appendChild(frag);
}
// opt: {me: 내 번호(0부터) 또는 -1, sel: 고른 칸, playing: 둘 수 있는지}
function renderBoard(el, v, opt={}){
  const cells=el.children, me=opt.me ?? -1;
  for(let i=0;i<v.C;i++){
    const d=cells[i], o=v.owner[i];
    d.style.background = o<0 ? '' : (v.base[i] ? v.colors[o].base : v.colors[o].tint);
    d.style.setProperty('--pc', o<0 ? '#3a342c' : v.colors[o].main);
    d.firstChild.textContent = v.value[i] || '';
    d.classList.toggle('base', v.base[i]);
    d.classList.toggle('given', v.given[i]);
    d.classList.toggle('solved', v.claimed.has(i));
    d.classList.toggle('legal', me>=0 && !!opt.playing && i!==opt.sel && legalFor(v,me,i));
    d.classList.toggle('sel', me>=0 && i===opt.sel);
  }
}
function popCell(el, i){
  const d=el.children[i]; if(!d) return;
  d.classList.remove('pop'); void d.offsetWidth; d.classList.add('pop');
}

/* ===== 순위 ===== */
function rankingHtml(v, players, meP=-1){
  const c=countsOf(v), stat=new Map(players.map(p=>[p.num-1,p]));
  const order=[...Array(v.n).keys()].sort((a,b)=>c[b]-c[a] || a-b);
  let rank=0;
  return order.map((p,k)=>{
    if(k===0 || c[p]!==c[order[k-1]]) rank=k+1;
    const label=['','🥇','🥈','🥉'][rank] || `${rank}위`, s=stat.get(p) || {atk:0,def:0};
    return `<div class="rank ${p===meP?'me':''}"><b>${label}</b>${dotHtml(v.colors,p)}<span class="nm">${nm(p)}</span><span>${c[p]}칸 · ⚔️${s.atk} 🛡️${s.def}</span></div>`;
  }).join('');
}
function kingsTitle(v){
  const c=countsOf(v), top=Math.max(...c), kings=[...Array(v.n).keys()].filter(p=>c[p]===top);
  return kings.length>1 ? `공동 스도쿠왕: ${kings.map(nm).join(', ')}` : `스도쿠왕은 ${nm(kings[0])}!`;
}

/* ===== 실시간 연결 =====
   변화는 알림으로 받고, 혹시 놓친 게 있을까 봐 30초마다 한 번만 전체를 다시 맞춘다. */
function subscribeRoom(roomId, h){
  const ch = sb.channel('sudoku-'+roomId)
    .on('postgres_changes', {event:'INSERT', schema:'public', table:'sudoku_claims', filter:`room_id=eq.${roomId}`}, e=>h.onClaim?.(e.new))
    .on('postgres_changes', {event:'*', schema:'public', table:'sudoku_players', filter:`room_id=eq.${roomId}`}, e=>h.onPlayer?.(e.new))
    .on('postgres_changes', {event:'UPDATE', schema:'public', table:'sudoku_rooms', filter:`id=eq.${roomId}`}, e=>h.onRoom?.(e.new))
    .subscribe(status=>h.onStatus?.(status));
  const timer = setInterval(()=>h.resync?.(), 30000);
  return ()=>{ clearInterval(timer); sb.removeChannel(ch); };
}
async function fetchRoom(roomId){
  const { data, error } = await sb.from('sudoku_rooms').select('*').eq('id', roomId).maybeSingle();
  if(error) throw error; return data;
}
async function fetchRoomStatus(roomId){
  const { data, error } = await sb.from('sudoku_rooms').select('status,started_at,ends_at').eq('id', roomId).maybeSingle();
  if(error) throw error; return data;
}
async function fetchClaims(roomId){
  const { data, error } = await sb.from('sudoku_claims').select('cell,player,prev_owner,value,created_at').eq('room_id', roomId).order('created_at');
  if(error) throw error; return data;
}
async function fetchPlayers(roomId){
  const { data, error } = await sb.from('sudoku_players').select('num,atk,def,miss,joined_at').eq('room_id', roomId).order('num');
  if(error) throw error; return data;
}

/* ===== 알림 ===== */
let toastT=null;
function toast(msg, ms=1800){
  const t=$('toast'); t.textContent=msg; t.classList.add('show');
  clearTimeout(toastT); toastT=setTimeout(()=>t.classList.remove('show'), ms);
}
function claimMessage(cl){
  const me=cl.player, prev=cl.prev_owner;
  if(prev===me) return `🛡️ ${nm(me)} 수비 성공`;
  if(prev<0) return `🚩 ${nm(me)}, 빈 땅 차지`;
  return `⚔️ ${nm(me)}이(가) ${nm(prev)} 땅을 빼앗았어요!`;
}
// 이 기기 시계와 데이터베이스 시계의 차이(밀리초). 남은 시간을 모든 기기에서 똑같이 보여 주려고.
async function measureSkew(){
  try{
    const t0 = Date.now();
    const now = await call('sudoku_now', {});
    return Date.parse(now) - (t0 + Date.now())/2;
  }catch(e){ return 0; }
}
const fmtTime = s => { s=Math.max(0,Math.ceil(s)); return `${Math.floor(s/60)}:${String(s%60).padStart(2,'0')}`; };
