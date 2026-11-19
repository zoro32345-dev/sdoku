/* 🧩 스도쿠 연습 — 스도쿠를 아예 모르는 아이를 위한 혼자 하기 (2026-11-19)
 *
 * 서버를 쓰지 않습니다. 이 기기 안에서 문제를 만들고 채점합니다.
 * 그래서 인터넷 요금도, 동시 접속도, 한 달 횟수도 건드리지 않아요.
 *
 * 4×4 로 시작해서 6×6, 9×9 로 넓혀 갑니다.
 * 틀리면 "왜 안 되는지"를 그 자리에서 알려 줍니다. 그게 이 연습의 전부입니다.
 */
window.Practice = (() => {
  const $p = (id) => document.getElementById(id);
  const 섞기 = (a) => { const b = a.slice(); for (let i = b.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [b[i], b[j]] = [b[j], b[i]]; } return b; };
  const 줄세우기 = (n) => Array.from({ length: n }, (_, i) => i);

  // ── 단계 ────────────────────────────────────────────────
  // 칸: 가로 N칸. 네모: 세로 boxH × 가로 boxW. 빈칸: 몇 개를 비울지.
  const 단계들 = [
    { 이름: "4×4", N: 4, boxH: 2, boxW: 2, 빈칸: 4, 판수: 2,
      말: "숫자는 1부터 4까지만 써요" },
    { 이름: "4×4", N: 4, boxH: 2, boxW: 2, 빈칸: 7, 판수: 2,
      말: "이번엔 빈칸이 조금 더 많아요" },
    { 이름: "6×6", N: 6, boxH: 2, boxW: 3, 빈칸: 9, 판수: 2,
      말: "숫자가 6까지 늘었어요. 네모는 옆으로 긴 모양이에요" },
    { 이름: "9×9", N: 9, boxH: 3, boxW: 3, 빈칸: 12, 판수: 1,
      말: "진짜 스도쿠예요! 대결에 나오는 판과 똑같아요" },
  ];

  // ── 문제 만들기 ──────────────────────────────────────────
  // 규칙을 지키는 판을 하나 만들고(아래 식), 줄·칸·숫자를 섞어 매번 다르게 합니다.
  function 꽉찬판(N, boxH, boxW) {
    const 자리 = (r, c) => (boxW * (r % boxH) + Math.floor(r / boxH) + c) % N;
    const 띠 = 섞기(줄세우기(N / boxH)), 기둥 = 섞기(줄세우기(N / boxW));
    const 줄 = [], 칸 = [];
    띠.forEach((g) => 섞기(줄세우기(boxH)).forEach((i) => 줄.push(g * boxH + i)));
    기둥.forEach((g) => 섞기(줄세우기(boxW)).forEach((i) => 칸.push(g * boxW + i)));
    const 숫자 = 섞기(줄세우기(N).map((i) => i + 1));
    const 판 = [];
    for (let r = 0; r < N; r++) for (let c = 0; c < N; c++) 판[r * N + c] = 숫자[자리(줄[r], 칸[c])];
    return 판;
  }

  // 답이 하나뿐인지 봅니다 (두 개째를 찾으면 바로 멈춥니다)
  function 답개수(판, N, boxH, boxW, 그만 = 2) {
    const 쓸수있나 = (p, i, v) => {
      const r = Math.floor(i / N), c = i % N;
      for (let k = 0; k < N; k++) if (p[r * N + k] === v || p[k * N + c] === v) return false;
      const br = Math.floor(r / boxH) * boxH, bc = Math.floor(c / boxW) * boxW;
      for (let a = 0; a < boxH; a++) for (let b = 0; b < boxW; b++)
        if (p[(br + a) * N + bc + b] === v) return false;
      return true;
    };
    let 센것 = 0;
    const 풀기 = (p) => {
      let 빈 = -1;
      for (let i = 0; i < p.length; i++) if (!p[i]) { 빈 = i; break; }
      if (빈 < 0) { 센것++; return; }
      for (let v = 1; v <= N && 센것 < 그만; v++) {
        if (!쓸수있나(p, 빈, v)) continue;
        p[빈] = v; 풀기(p); p[빈] = 0;
      }
    };
    풀기(판.slice());
    return 센것;
  }

  function 문제만들기(단) {
    const { N, boxH, boxW, 빈칸 } = 단;
    const 답 = 꽉찬판(N, boxH, boxW);
    const 문제 = 답.slice();
    let 지운수 = 0;
    for (const i of 섞기(줄세우기(N * N))) {
      if (지운수 >= 빈칸) break;
      const 두었던 = 문제[i];
      문제[i] = 0;
      if (답개수(문제, N, boxH, boxW) === 1) 지운수++;
      else 문제[i] = 두었던;          // 답이 여러 개가 되면 되돌립니다
    }
    return { 문제, 답 };
  }

  // ── 왜 안 되는지 찾기 ────────────────────────────────────
  function 왜안되나(칸값, N, boxH, boxW, i, v) {
    const r = Math.floor(i / N), c = i % N;
    for (let k = 0; k < N; k++) if (k !== c && 칸값[r * N + k] === v) return "가로줄";
    for (let k = 0; k < N; k++) if (k !== r && 칸값[k * N + c] === v) return "세로줄";
    const br = Math.floor(r / boxH) * boxH, bc = Math.floor(c / boxW) * boxW;
    for (let a = 0; a < boxH; a++) for (let b = 0; b < boxW; b++) {
      const j = (br + a) * N + bc + b;
      if (j !== i && 칸값[j] === v) return "네모";
    }
    return null;
  }

  // ── 상태 ────────────────────────────────────────────────
  let 단계 = 0, 판차례 = 0, 지금 = null, 고른칸 = -1, 틀린수 = 0, 끝났을때 = null;

  function 새판() {
    const 단 = 단계들[단계];
    const { 문제, 답 } = 문제만들기(단);
    지금 = { 단, 문제, 답, 값: 문제.slice() };
    고른칸 = -1;
    그리기();
    말하기(단.말, "");
  }

  function 말하기(글, 꼴) {
    const el = $p("prTip");
    el.textContent = 글;
    el.className = "pr-tip" + (꼴 ? " " + 꼴 : "");
  }

  function 그리기() {
    const { 단, 문제, 값 } = 지금;
    const { N, boxH, boxW } = 단;
    $p("prStep").textContent = `${단계 + 1}단계 ${단.이름} · ${판차례 + 1} / ${단.판수}`;
    const 남은 = 값.filter((v, i) => !문제[i] && !v).length;
    $p("prLeft").textContent = 남은 ? `빈칸 ${남은}개 남았어요` : "다 채웠어요!";

    let html = "";
    for (let i = 0; i < N * N; i++) {
      const r = Math.floor(i / N), c = i % N;
      const 준것 = !!문제[i], v = 값[i];
      const 테두리 = [
        r % boxH === 0 ? "bt" : "", c % boxW === 0 ? "bl" : "",
        r === N - 1 ? "bb" : "", c === N - 1 ? "br" : "",
      ].filter(Boolean).join(" ");
      html += `<button type="button" class="pr-cell ${준것 ? "given" : ""} ${i === 고른칸 ? "sel" : ""} ${테두리}"
        data-i="${i}" ${준것 ? "disabled" : ""}>${v || ""}</button>`;
    }
    const 판 = $p("prGrid");
    판.style.setProperty("--n", N);
    판.innerHTML = html;

    let pad = "";
    for (let v = 1; v <= N; v++) pad += `<button type="button" class="pr-num" data-v="${v}">${v}</button>`;
    pad += `<button type="button" class="pr-num del" data-v="0">지우기</button>`;
    $p("prPad").innerHTML = pad;
    $p("prPad").style.setProperty("--n", N <= 4 ? 5 : N <= 6 ? 4 : 5);
  }

  function 눌렀다(i) {
    if (지금.문제[i]) return;
    고른칸 = i;
    그리기();
    말하기("1부터 " + 지금.단.N + "까지 중에 골라요", "");
  }

  function 넣는다(v) {
    if (고른칸 < 0) { 말하기("먼저 빈칸을 하나 눌러요", "warn"); return; }
    const { 단, 답, 값 } = 지금;
    const i = 고른칸;
    if (v === 0) { 값[i] = 0; 그리기(); 말하기("지웠어요", ""); return; }

    const 까닭 = 왜안되나(값, 단.N, 단.boxH, 단.boxW, i, v);
    if (까닭) {
      틀린수++;
      말하기(`같은 ${까닭}에 ${v}가 벌써 있어요. 다른 숫자를 골라요`, "bad");
      흔들기(i);
      return;
    }
    if (v !== 답[i]) {
      틀린수++;
      말하기(`여기는 ${v}가 아니에요. 가로줄·세로줄·네모를 다시 살펴봐요`, "bad");
      흔들기(i);
      return;
    }
    값[i] = v;
    고른칸 = -1;
    그리기();
    const 남은 = 값.filter((x, k) => !지금.문제[k] && !x).length;
    if (남은) 말하기(["좋아요!", "맞았어요!", "잘했어요!"][Math.floor(Math.random() * 3)], "good");
    else 한판끝();
  }

  function 흔들기(i) {
    const el = $p("prGrid").querySelector(`[data-i="${i}"]`);
    if (!el) return;
    el.classList.remove("shake"); void el.offsetWidth; el.classList.add("shake");
  }

  function 한판끝() {
    판차례++;
    const 단 = 단계들[단계];
    if (판차례 < 단.판수) {
      말하기("한 판 끝! 다음 판으로 가요 🎉", "good");
      setTimeout(새판, 1200);
      return;
    }
    판차례 = 0;
    단계++;
    if (단계 < 단계들.length) {
      말하기(`${단.이름} 다 했어요! 이제 ${단계들[단계].이름} 해 볼까요? 🎉`, "good");
      setTimeout(새판, 1600);
      return;
    }
    다끝남();
  }

  function 다끝남() {
    $p("prPlay").hidden = true;
    $p("prDone").hidden = false;
    $p("prDoneMsg").textContent = 틀린수 === 0
      ? "한 번도 안 틀렸어요! 정말 잘하네요 🏆"
      : `틀린 건 ${틀린수}번뿐이에요. 이제 대결해도 괜찮아요 👍`;
  }

  // ── 규칙 알려 주기 ───────────────────────────────────────
  const 규칙들 = [
    { ic: "↔️", 제목: "가로줄", 글: "한 가로줄 안에 같은 숫자가 두 번 있으면 안 돼요" },
    { ic: "↕️", 제목: "세로줄", 글: "한 세로줄 안에도 같은 숫자가 두 번 있으면 안 돼요" },
    { ic: "🔲", 제목: "네모 칸", 글: "굵은 선으로 묶인 네모 안에서도 마찬가지예요" },
  ];

  function 규칙보이기() {
    $p("prRules").innerHTML = 규칙들.map((r) =>
      `<div class="pr-rule"><span class="ic">${r.ic}</span><b>${r.제목}</b><small>${r.글}</small></div>`).join("");
  }

  // ── 열고 닫기 ────────────────────────────────────────────
  function 열기(돌아갈곳) {
    끝났을때 = 돌아갈곳 || null;
    단계 = 0; 판차례 = 0; 틀린수 = 0;
    규칙보이기();
    $p("prIntro").hidden = false;
    $p("prPlay").hidden = true;
    $p("prDone").hidden = true;
    document.querySelectorAll("#home,#join,#wait,#play").forEach((e) => { e.hidden = true; });
    $p("learn").hidden = false;
    window.scrollTo(0, 0);
  }

  function 닫기() {
    $p("learn").hidden = true;
    if (typeof 끝났을때 === "function") 끝났을때();
  }

  function 시작() {
    $p("prIntro").hidden = true;
    $p("prPlay").hidden = false;
    새판();
  }

  // ── 단추 달기 ────────────────────────────────────────────
  function 붙이기() {
    $p("prGo").onclick = 시작;
    $p("prAgain").onclick = () => { 단계 = 0; 판차례 = 0; 틀린수 = 0; $p("prDone").hidden = true; $p("prPlay").hidden = false; 새판(); };
    document.querySelectorAll("[data-pr-close]").forEach((b) => { b.onclick = 닫기; });
    $p("prGrid").addEventListener("click", (e) => {
      const b = e.target.closest("[data-i]"); if (b && !b.disabled) 눌렀다(Number(b.dataset.i));
    });
    $p("prPad").addEventListener("click", (e) => {
      const b = e.target.closest("[data-v]"); if (b) 넣는다(Number(b.dataset.v));
    });
  }

  return { 열기, 닫기, 붙이기 };
})();
