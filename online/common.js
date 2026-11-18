/* 스도쿠왕 쟁탈전 (동시 대결) — 선생님·학생 화면이 함께 쓰는 코드 */

/* ===== Supabase 연결 =====
   아래 열쇠는 "공개용"이라 화면 코드에 있어도 괜찮다.
   학생 쪽에서 할 수 있는 일은 데이터베이스 규칙과 함수가 막고 있다(supabase/*.sql). */
const SB_URL = 'https://yhfvvsenuqnfdtcjlnbz.supabase.co';
const SB_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InloZnZ2c2VudXFuZmR0Y2psbmJ6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTMwNDY5MzMsImV4cCI6MjEwODYyMjkzM30.PNU720EekIf_uR6NAUgi-F2wzVmtHKj6M3fnxdlfDHI';
const sb = window.supabase.createClient(SB_URL, SB_KEY, { auth: { persistSession: false } });

const $ = id => document.getElementById(id);
const esc = s => String(s).replace(/[&<>"]/g, ch => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[ch]));
// 땅 주인 이름: 개인전이면 "3번", 모둠 대항이면 "3모둠" (makeView가 모드를 정한다)
let OWNER_UNIT = '번';
const nm = p => `${p+1}${OWNER_UNIT}`;
const MODE_LABEL = {solo:'개인전', team:'모둠 대항'};

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
// keepLocal: 꼭 보여 줄 칸. givenSol을 주면 그 정답으로 빈칸 모양만 새로 만든다(공격용 문제).
function makePuzzle(keepLocal, diff, givenSol){
  const sol = givenSol ? givenSol.slice() : new Array(81).fill(0);
  if(!givenSol) fillFull(sol);
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
// 지도 크기: 인원에 맞춘 기본 크기에서 boost만큼 판을 더 이어 붙인다 (최대 5×5장 = 45×45칸)
const MAX_K = 5;
const mapK = (n, boost=0) => Math.min(MAX_K, blocksFor(n) + boost);
// 인원·난이도로 지도 전체를 만든다. 결과는 데이터베이스에 그대로 보낸다.
function buildMap(n, diff, boost=0){
  const K=mapK(n, boost), B=3*K, W=9*K, C=W*W;
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

  const sol=new Array(C), puzzle=new Array(C), maskOpen=new Array(C);
  for(let BY=0;BY<K;BY++) for(let BX=0;BX<K;BX++){
    const g2l = (r,c)=>(BY*9+r)*W + BX*9+c;
    const keep = Array.from({length:81},(_,j)=>base[g2l(Math.floor(j/9), j%9)]);
    const {sol:s, puz} = makePuzzle(keep, diff);
    // 공격용 문제: 같은 정답, 본진을 꼭 보여 주지 않는 빈칸 모양 (본진 공격 때 바뀐다)
    const {puz:open} = makePuzzle(new Array(81).fill(false), diff, s);
    for(let j=0;j<81;j++){ const i=g2l(Math.floor(j/9), j%9); sol[i]=s[j]; puzzle[i]=puz[j]; maskOpen[i]=open[j]!==0; }
  }
  return {n, K, W, C, sol, puzzle, owner, base, maskOpen};
}

/* ===== 방 정보 → 화면 상태 ===== */
// room: sudoku_rooms 한 줄. claims: sudoku_claims 여러 줄
function makeView(room){
  const W=room.k*9, C=W*W;
  const mode = room.mode || 'solo';
  OWNER_UNIT = mode==='team' ? '모둠' : '번';
  const v = {
    room, mode, team: mode==='team', students: room.students || room.n,
    n:room.n, K:room.k, W, C,
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
// 칸 하나 반영. solved=false 면 땅 주인은 그대로, 숫자만 다시 빈칸(새 문제가 나온 판)
function applyClaim(v, cl){
  const solved = cl.solved !== false;
  if(solved){
    if(v.claimed.has(cl.cell) && v.owner[cl.cell]===cl.player && v.value[cl.cell]===cl.value) return false;
    v.owner[cl.cell]=cl.player; v.value[cl.cell]=cl.value; v.claimed.add(cl.cell);
  } else {
    v.owner[cl.cell]=cl.player; v.value[cl.cell]=v.room.puzzle[cl.cell]||0; v.claimed.delete(cl.cell);
  }
  return true;
}
// 방(문제)과 칸 목록으로 화면 상태를 처음부터 다시 맞춘다 (새 문제·본진 공격 뒤)
function rebuildView(v, room, claims){
  Object.assign(v.room, room);
  v.owner = v.room.init_owner.slice();
  v.value = v.room.puzzle.slice();
  v.given = v.room.puzzle.map(x=>x>0);
  v.claimed = new Set();
  claims.forEach(cl=>applyClaim(v, cl));
}
const isBlank = (v,i) => v.value[i]===0;
const blanksLeft = v => v.value.filter(x=>x===0).length;
// 이 주인(p)이 지금 고를 수 있는 칸. 하나도 없으면 낙하산: 모든 빈칸
// tickets: 역전 찬스 표 개수(있으면 아무 빈칸이나). 황금 칸은 누구나 고를 수 있다.
function movesFor(v, p, tickets=0){
  const m = movesRaw(v, p, tickets);
  [...m.cells].forEach(i=>{ if(isShielded(v,i,p)) m.cells.delete(i); });   // 방패 중인 친구 본진은 빼기
  return m;
}
function movesRaw(v, p, tickets){
  const cells = new Set();
  const g = v.room.gold_cell;
  if(tickets>0){ for(let i=0;i<v.C;i++) if(isBlank(v,i)) cells.add(i); return {cells, para:false, ticket:true}; }
  for(let i=0;i<v.C;i++) if(legalFor(v,p,i)) cells.add(i);
  if(cells.size){ if(g!=null && isBlank(v,g)) cells.add(g); return {cells, para:false}; }
  for(let i=0;i<v.C;i++) if(isBlank(v,i)) cells.add(i);
  return {cells, para:true};
}
// 방 정보 중 실시간으로 바뀌는 것들 (황금 칸, 피버, 역전 찬스 등)
const ROOM_EXTRA = ['gold_cell','golds','gold_by','gold_by_num','gold_last','fever_until','chances',
  'shield_until','shield_used','fallen','falls','last_fall_victim','last_fall_by','last_fall_num','retakes','last_retake'];
// 본진 방패: q(주인)의 방패가 지금 켜져 있는지
const shieldOn = (v, q) => { const t = v.room.shield_until && v.room.shield_until[q]; return !!t && Date.parse(t) > Date.now() + (v.skew||0); };
const shieldLeft = (v, q) => { const t = v.room.shield_until && v.room.shield_until[q]; return t ? Math.max(0, (Date.parse(t) - Date.now() - (v.skew||0))/1000) : 0; };
const shieldKey = v => [...Array(v.n).keys()].filter(q=>shieldOn(v,q)).join(',');
// 내 본진 칸 중 아직 내 땅인 칸 수
function baseHp(v, q){ let mine=0, total=0; for(let i=0;i<v.C;i++) if(v.base[i] && v.room.init_owner[i]===q){ total++; if(v.owner[i]===q) mine++; } return {mine, total}; }
const isShielded = (v, i, p) => v.base[i] && v.room.init_owner[i]!==p && shieldOn(v, v.room.init_owner[i]);
function copyRoomExtra(v, r){ ROOM_EXTRA.concat(['reblanks','last_box']).forEach(k=>{ if(r[k]!==undefined) v.room[k]=r[k]; }); }
const goldAlive = v => v.room.gold_cell!=null && isBlank(v, v.room.gold_cell);
const feverLeft = (v, skew=0) => v.room.fever_until ? Math.max(0, (Date.parse(v.room.fever_until) - (Date.now()+skew))/1000) : 0;
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
// opt: {me: 내 번호(0부터) 또는 -1, sel: 고른 칸, playing: 둘 수 있는지, legal: 고를 수 있는 칸 Set}
function renderBoard(el, v, opt={}){
  const cells=el.children, me=opt.me ?? -1;
  el.classList.toggle('open', !!v.room.base_open);
  const legal = opt.legal || null;
  for(let i=0;i<v.C;i++){
    const d=cells[i], o=v.owner[i];
    d.style.background = o<0 ? '' : (v.base[i] ? v.colors[o].base : v.colors[o].tint);
    d.style.setProperty('--pc', o<0 ? '#3a342c' : v.colors[o].main);
    d.firstChild.textContent = v.value[i] || '';
    d.classList.toggle('base', v.base[i]);
    d.classList.toggle('given', v.given[i]);
    d.classList.toggle('solved', v.claimed.has(i));
    d.classList.toggle('legal', me>=0 && !!opt.playing && i!==opt.sel && (legal ? legal.has(i) : legalFor(v,me,i)));
    d.classList.toggle('sel', me>=0 && i===opt.sel);
    d.classList.toggle('gold', i===v.room.gold_cell && isBlank(v,i) && v.room.status==='playing');
    d.classList.toggle('shield', v.base[i] && v.room.status==='playing' && shieldOn(v, v.room.init_owner[i]));
  }
}
function popCell(el, i){
  const d=el.children[i]; if(!d) return;
  d.classList.remove('pop'); void d.offsetWidth; d.classList.add('pop');
}
// 새 문제가 나온 판(block 번호)을 반짝이게
function flashBlock(el, v, block){
  if(block==null) return;
  const by=Math.floor(block/v.K), bx=block%v.K;
  for(let r=0;r<9;r++) for(let c=0;c<9;c++){
    const d=el.children[(by*9+r)*v.W + bx*9+c]; if(!d) continue;
    d.classList.remove('fresh'); void d.offsetWidth; d.classList.add('fresh');
  }
}

// 다시 빈칸이 된 3×3(box 번호 = 3×3 줄*가로개수 + 3×3 칸)을 반짝이게
function flashBox(el, v, box){
  if(box==null) return;
  const n=v.K*3, gy=Math.floor(box/n), gx=box%n;
  for(let r=0;r<3;r++) for(let c=0;c<3;c++){
    const d=el.children[(gy*3+r)*v.W + gx*3+c]; if(!d) continue;
    d.classList.remove('fresh'); void d.offsetWidth; d.classList.add('fresh');
  }
}

/* ===== 순위 ===== */
// 땅 주인(학생 또는 모둠)별 공격·수비 합계
function statsByOwner(v, players){
  const s = Array.from({length:v.n},()=>({atk:0,def:0,members:0}));
  players.forEach(pl=>{ const t = pl.team ?? (pl.num-1); if(s[t]){ s[t].atk+=pl.atk||0; s[t].def+=pl.def||0; s[t].members++; } });
  return s;
}
function rankOrder(v){
  const c=countsOf(v);
  const order=[...Array(v.n).keys()].sort((a,b)=>c[b]-c[a] || a-b);
  const ranks=[]; order.forEach((p,k)=>{ ranks[p] = (k>0 && c[p]===c[order[k-1]]) ? ranks[order[k-1]] : k+1; });
  return {c, order, ranks};
}
const medal = r => ['','🥇','🥈','🥉'][r] || `${r}위`;
function rankingHtml(v, players, meP=-1){
  const {c, order, ranks}=rankOrder(v), st=statsByOwner(v, players);
  return order.map(p=>`<div class="rank ${p===meP?'me':''}"><b>${medal(ranks[p])}</b>${dotHtml(v.colors,p)}<span class="nm">${nm(p)}</span><span>${c[p]}칸 · ⚔️${st[p].atk} 🛡️${st[p].def}</span></div>`).join('');
}
// 모둠 대항일 때: 가장 많이 푼 학생 3명
function mvpHtml(v, players){
  const list = players.map(p=>({...p, score:(p.atk||0)+(p.def||0)})).filter(p=>p.score>0)
    .sort((a,b)=>b.score-a.score || b.atk-a.atk || a.num-b.num).slice(0,3);
  if(!list.length) return '';
  return `<div class="mvp"><b>🌟 우리 반 MVP</b>${list.map((p,k)=>`<span>${['🥇','🥈','🥉'][k]} ${p.num}번 <small>(${nm(p.team)}) ${p.score}칸</small></span>`).join('')}</div>`;
}

// 결과 화면 칭호: 여러 아이가 받을 수 있게
const TITLES = [
  ['👑','정복왕','conquers', n=>`본진 함락 ${n}번`],
  ['⚔️','공격왕','atk', n=>`${n}칸 빼앗음`],
  ['🛡️','수비왕','def', n=>`${n}칸 지킴`],
  ['🌟','황금손','golds', n=>`황금 칸 ${n}번`],
  ['✨','마무리왕','boxes', n=>`3×3 완성 ${n}번`],
  ['🪂','낙하산왕','para', n=>`${n}번 착륙`],
];
function titlesHtml(players, meNum=-1){
  const who = list => list.length>3 ? list.slice(0,3).map(p=>p.num+'번').join(', ')+` 외 ${list.length-3}명` : list.map(p=>p.num+'번').join(', ');
  const cards = [];
  TITLES.forEach(([ic,name,key,desc])=>{
    const top = Math.max(0, ...players.map(p=>p[key]||0)); if(!top) return;
    const list = players.filter(p=>(p[key]||0)===top);
    cards.push({ic,name,list,desc:desc(top)});
  });
  // 정확왕: 5칸 이상 푼 학생 중 틀린 비율이 가장 낮은 학생
  const ok = players.filter(p=>(p.atk||0)+(p.def||0)>=5).map(p=>({...p, solved:(p.atk||0)+(p.def||0), rate:(p.miss||0)/((p.atk||0)+(p.def||0)+(p.miss||0))}));
  if(ok.length){
    const best = Math.min(...ok.map(p=>p.rate));
    const list = ok.filter(p=>p.rate===best).sort((a,b)=>b.solved-a.solved);
    cards.splice(2,0,{ic:'🎯',name:'정확왕',list,desc:`틀림 ${list[0].miss||0}번`});
  }
  if(!cards.length) return '';
  return `<div class="titles"><b>🏅 오늘의 칭호</b>${cards.map(c=>`<div class="tcard ${c.list.some(p=>p.num===meNum)?'me':''}"><span class="ti">${c.ic}</span><span class="tn">${c.name}</span><span class="tw">${who(c.list)}</span><small>${c.desc}</small></div>`).join('')}</div>`;
}

/* 실시간 순위표: 순서가 바뀌면 줄이 미끄러지듯 움직인다
   opt: {meP: 강조할 주인, limit: 위에서 몇 줄까지, extra: (p)=>추가 글자, onClick} */
function renderLiveRank(el, v, players, opt={}){
  const {c, order, ranks} = rankOrder(v), st = statsByOwner(v, players);
  const max = Math.max(1, ...c);
  let show = order.slice(0, opt.limit || order.length);
  if(opt.meP>=0 && !show.includes(opt.meP)) show = show.slice(0, show.length-1).concat(opt.meP);
  // 1) 지금 위치 기억
  const before = new Map([...el.children].map(r=>[r.dataset.p, r.getBoundingClientRect().top]));
  // 2) 줄 만들기·고치기
  const keep = new Set(show.map(String));
  [...el.children].forEach(r=>{ if(!keep.has(r.dataset.p)) r.remove(); });
  show.forEach(p=>{
    let row = el.querySelector(`[data-p="${p}"]`);
    if(!row){
      row = document.createElement('div'); row.className='lrow'; row.dataset.p=p;
      row.innerHTML = `<b class="rk"></b>${dotHtml(v.colors,p)}<span class="nm"></span><span class="lbar"><i style="background:${v.colors[p].main}"></i></span><span class="ct"></span>`;
      if(opt.onClick) row.onclick = ()=>opt.onClick(p);
      el.appendChild(row);
    }
    const prevCount = Number(row.dataset.c ?? c[p]);
    row.querySelector('.rk').textContent = medal(ranks[p]);
    row.querySelector('.nm').textContent = nm(p) + (opt.extra ? opt.extra(p, st[p]) : '');
    row.querySelector('.lbar i').style.width = (c[p]/max*100)+'%';
    row.querySelector('.ct').textContent = c[p];
    row.classList.toggle('me', p===opt.meP);
    row.classList.toggle('dim', !!opt.dim && opt.dim(p));
    if(c[p]>prevCount){ row.classList.remove('up'); void row.offsetWidth; row.classList.add('up'); }
    if(c[p]<prevCount){ row.classList.remove('down'); void row.offsetWidth; row.classList.add('down'); }
    row.dataset.c = c[p];
    el.appendChild(row); // 순서대로 다시 붙이기
  });
  // 3) 예전 위치에서 새 위치로 움직이기
  [...el.children].forEach(r=>{
    const old = before.get(r.dataset.p); if(old===undefined) return;
    const dy = old - r.getBoundingClientRect().top; if(!dy) return;
    r.style.transition='none'; r.style.transform=`translateY(${dy}px)`;
    requestAnimationFrame(()=>{ r.style.transition='transform .45s ease'; r.style.transform=''; });
  });
}
function kingsTitle(v){
  const c=countsOf(v), top=Math.max(...c), kings=[...Array(v.n).keys()].filter(p=>c[p]===top);
  return kings.length>1 ? `공동 스도쿠왕: ${kings.map(nm).join(', ')}` : `스도쿠왕은 ${nm(kings[0])}!`;
}

/* ===== 실시간 연결 =====
   변화는 알림으로 받고, 혹시 놓친 게 있을까 봐 30초마다 한 번만 전체를 다시 맞춘다. */
function subscribeRoom(roomId, h){
  const ch = sb.channel('sudoku-'+roomId)
    .on('postgres_changes', {event:'*', schema:'public', table:'sudoku_claims', filter:`room_id=eq.${roomId}`}, e=>{ if(e.new && e.new.cell!=null) h.onClaim?.(e.new); })
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
  const { data, error } = await sb.from('sudoku_rooms').select('status,started_at,ends_at,puzzle,base_open,refreshes,last_block,reblanks,last_box,'+ROOM_EXTRA.join(',')).eq('id', roomId).maybeSingle();
  if(error) throw error; return data;
}
async function fetchClaims(roomId){
  const { data, error } = await sb.from('sudoku_claims').select('cell,player,prev_owner,value,by_num,solved,created_at').eq('room_id', roomId).order('created_at');
  if(error) throw error; return data;
}
async function fetchPlayers(roomId){
  const { data, error } = await sb.from('sudoku_players').select('num,team,atk,def,miss,para,boxes,golds,tickets,conquers,joined_at').eq('room_id', roomId).order('num');
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
  const who = OWNER_UNIT==='모둠' && cl.by_num ? `${nm(me)} ${cl.by_num}번` : nm(me);
  if(prev===me) return `🛡️ ${who} 수비 성공`;
  if(prev<0) return `🚩 ${who}, 빈 땅 차지`;
  return `⚔️ ${who}이(가) ${nm(prev)} 땅을 빼앗았어요!`;
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

/* ===== 게임 방법 슬라이드 =====
   선생님 TV(크게)와 학생 기다리기 화면(작게)에서 같이 쓴다.
   demo: 작은 그림판. R=내 본진 r=내 땅 B=친구 본진 b=친구 땅 .=빈 땅 *=고를 수 있는 칸 G=황금 칸 S=방패 본진 */
const RULE_SLIDES = [
  {ic:'👑', t:'땅을 가장 많이 차지하면 스도쿠왕!', l:['스도쿠 빈칸을 맞혀서 내 땅을 넓혀요.','차례 없이 모두 동시에! 내 기기로 해요.']},
  {ic:'🏠', t:'번호표 줄무늬 3×3이 내 본진', l:['처음엔 본진과 그 둘레가 내 땅이에요.','내 색깔을 기억해요!'], demo:['RRRr.','RRRr.','RRRr.','rrrr.','.....']},
  {ic:'⚔️', t:'점선 칸을 골라 숫자를 맞혀요', l:['내 땅에 붙은 점선 칸만 고를 수 있어요.','친구 땅도 맞히면 내 땅! 빈 땅도 내 땅!'], demo:['rrr*b','rrr*b','rr**b','*..bb','..bbb']},
  {ic:'🛡️', t:'먼저 맞힌 사람이 임자!', l:['같은 칸은 먼저 맞힌 친구 것이에요.','틀리면 5초 쉬어요. 천천히 정확하게!','내 땅 빈칸을 맞히면 그 칸을 지켜요.']},
  {ic:'✨', t:'판은 끝없이 계속돼요', l:['3×3을 다 채우면 그 자리가 다시 빈칸!','9×9 판의 3×3을 모두 채우면 새 문제!','🪂 둘 곳이 없으면 낙하산: 아무 빈칸이나!']},
  {ic:'🌟', t:'깜짝 이벤트', l:['🌟 황금 칸: 누구나 풀 수 있고 둘레 8칸까지 내 땅!','⚡ 피버 타임: 1분 동안 틀려도 안 쉬어요','🎟️ 역전 찬스: 땅이 적은 친구는 아무 빈칸 한 번!'], demo:['bb.rr','b...r','..G..','.....','rr.bb']},
  {ic:'🔥', t:'본진 공격! (선생님이 열면)', l:['본진에도 빈칸이 생겨 빼앗을 수 있어요.','🛡️ 방패 한 번: 30초 동안 내 본진을 못 빼앗아요.','👑 본진 빈칸을 모두 빼앗으면 함락! 9칸 모두 내 땅','🏰 빼앗겨도 탈락 없음! 역전 찬스 2장으로 되찾아요'], demo:['SSS..','SSS..','SSS*b','..*BB','..bBB']},
  {ic:'🏅', t:'끝나면 칭호를 받아요', l:['정복왕·공격왕·수비왕·정확왕·황금손·마무리왕·낙하산왕','땅이 적어도 칭호는 받을 수 있어요. 준비됐나요?']},
];
function demoHtml(rows){
  const col = {R:'#e5484d',r:'#f7b9bb',B:'#3b82f6',b:'#bcd3fb','.':'#ece8df','*':'#ece8df',G:'#ffd54a',S:'#e5484d'};
  return `<div class="demo" style="grid-template-columns:repeat(${rows[0].length},1fr)">${rows.join('').split('').map(ch=>
    `<i class="${ch==='*'?'dl':''}${'RBS'.includes(ch)?' bs':''}${ch==='S'?' sh':''}${ch==='G'?' gd':''}" style="background:${col[ch]}"></i>`).join('')}</div>`;
}
// el 안에 슬라이드를 만든다. 반환: {go(k)}
function slidesWidget(el, big=false){
  let k = 0;
  el.classList.add('slides'); el.classList.toggle('big', big);
  el.innerHTML = `<div class="sl-body"></div><div class="sl-nav"><button class="soft sl-prev">◀ 이전</button><span class="sl-dots"></span><button class="soft sl-next">다음 ▶</button></div>`;
  const body = el.querySelector('.sl-body'), dots = el.querySelector('.sl-dots');
  const go = n => {
    k = (n + RULE_SLIDES.length) % RULE_SLIDES.length; const s = RULE_SLIDES[k];
    body.innerHTML = `<div class="sl-ic">${s.ic}</div><div class="sl-main"><h3>${s.t}</h3><ul>${s.l.map(x=>`<li>${x}</li>`).join('')}</ul></div>${s.demo?demoHtml(s.demo):''}`;
    dots.innerHTML = RULE_SLIDES.map((_,j)=>`<i class="${j===k?'on':''}"></i>`).join('');
    el.querySelector('.sl-next').textContent = k===RULE_SLIDES.length-1 ? '처음으로 ↺' : '다음 ▶';
  };
  el.querySelector('.sl-prev').onclick = ()=>go(k-1);
  el.querySelector('.sl-next').onclick = ()=>go(k+1);
  go(0);
  return {go:n=>go(n), next:()=>go(k+1), prev:()=>go(k-1)};
}
