//#region src/site.ts
var e = document.body, t = e.dataset.root ?? "./", n = e.dataset.module ?? "", r = (e) => new URL(t + e, location.href).href;
//#endregion
//#region src/drawer.ts
function i() {
	let t = document.getElementById("nav-toggle"), n = document.getElementById("scrim");
	if (!t) return;
	let r = (r) => {
		e.dataset.nav = r ? "open" : "closed", t.setAttribute("aria-expanded", String(r)), n && (n.hidden = !r);
	};
	r(!1), t.addEventListener("click", () => r(e.dataset.nav !== "open")), n?.addEventListener("click", () => r(!1)), document.addEventListener("keydown", (t) => {
		t.key === "Escape" && e.dataset.nav === "open" && r(!1);
	}), document.getElementById("sidebar")?.addEventListener("click", (e) => {
		e.target?.closest("a") && r(!1);
	});
}
//#endregion
//#region src/scratch.ts
var a = /* @__PURE__ */ new Uint8Array(512), o = /* @__PURE__ */ new Uint8Array(512);
function s(e) {
	if (e <= a.length) return;
	let t = a.length;
	for (; t < e;) t *= 2;
	let n = new Uint8Array(t);
	n.set(a);
	let r = new Uint8Array(t);
	r.set(o), a = n, o = r;
}
//#endregion
//#region src/index-format.ts
var c = 1395934284, l = 2, u = 52, d = new TextDecoder(), f = new TextEncoder(), p = /* @__PURE__ */ new Uint8Array(256);
for (let e = 0; e < 256; e++) p[e] = e >= 65 && e <= 90 ? e + 32 : e;
function m(e) {
	let t = (t) => (e[t] | e[t + 1] << 8 | e[t + 2] << 16) + e[t + 3] * 16777216, n = (t) => e[t] | e[t + 1] << 8;
	if (e.length < u || t(0) !== c || t(4) !== l) return null;
	let r = t(8), i = {
		bytes: e,
		count: r,
		names: t(16),
		restarts: t(24),
		restart: t(12),
		kindOf: t(36),
		moduleOf: t(40),
		labels: [],
		folds: /* @__PURE__ */ new Map(),
		narrow: null,
		score: new Uint16Array(r),
		length: new Uint16Array(r),
		id: r < 65536 ? new Uint16Array(r) : new Uint32Array(r)
	}, a = t(28), o = a + 4;
	for (let n = 0, r = t(a); n < r; n++) {
		let t = e[o];
		i.labels.push(d.decode(e.subarray(o + 1, o + 1 + t))), o += 1 + t;
	}
	let s = t(44);
	o = s + 4;
	for (let r = 0, a = t(s); r < a; r++) {
		let r = n(o + 4);
		i.folds.set(t(o), e.subarray(o + 6, o + 6 + r)), o += 6 + r;
	}
	return i;
}
function h(e, t, n) {
	let r = 0;
	for (let i = t; i < n; i++) {
		let t = e[i];
		(t & 192) != 128 && (r += t >= 240 ? 2 : 1);
	}
	return r;
}
function g(e, t) {
	let n = e.bytes, r = Math.floor(t / e.restart), i = e.restarts + r * 4, a = e.names + ((n[i] | n[i + 1] << 8 | n[i + 2] << 16) + n[i + 3] * 16777216), o = /* @__PURE__ */ new Uint8Array(256), s = 0;
	for (let i = r * e.restart; i <= t; i++) {
		let e = n[a++], t = n[a++];
		if (t === 255 && (t = n[a] | n[a + 1] << 8, a += 2), e + t > o.length) {
			let n = new Uint8Array(Math.max(e + t, o.length * 2));
			n.set(o), o = n;
		}
		o.set(n.subarray(a, a + t), e), a += t, s = e + t;
	}
	return d.decode(o.subarray(0, s));
}
var _ = (e, t) => e.labels[e.bytes[e.kindOf + t]] ?? "", v = (e, t) => e.bytes[e.moduleOf + t * 2] | e.bytes[e.moduleOf + t * 2 + 1] << 8;
function y(e, t) {
	let n = new Set(t), r = /* @__PURE__ */ new Map(), i = e.bytes, o = e.names;
	for (let t = 0; t < e.count && r.size < n.size; t++) {
		let e = i[o++], c = i[o++];
		c === 255 && (c = i[o] | i[o + 1] << 8, o += 2), s(e + c), a.set(i.subarray(o, o + c), e), o += c;
		let l = d.decode(a.subarray(0, e + c));
		n.has(l) && r.set(l, t);
	}
	return r;
}
//#endregion
//#region src/data.ts
var b = null, x = null, S = null, C = null, w = (e) => fetch(r(e)).then((e) => e.ok ? e.json() : Promise.reject(Error(String(e.status)))).catch(() => null);
function T() {
	return b ??= w("modules.json"), b;
}
function ee() {
	return x ??= fetch(r("search-index.bin")).then((e) => e.ok ? e.arrayBuffer() : Promise.reject(Error(String(e.status)))).then((e) => m(new Uint8Array(e))).catch(() => null), x;
}
function E() {
	return S ??= w("instances.json"), S;
}
function te() {
	return C ??= w("declarations/used-by.json"), C;
}
async function D() {
	let [e, t] = await Promise.all([T(), ee()]);
	return !e?.modules || !t ? null : {
		modules: e.modules,
		index: t
	};
}
//#endregion
//#region src/imported-by.ts
function O(e) {
	let t = document.createElement("span");
	return t.className = "count", t.textContent = ` ${e}`, t;
}
async function k() {
	let e = document.querySelector("[data-fill=\"imported-by\"]");
	if (!e) return;
	let t = await T(), i = (t?.modules?.find((e) => e.n === n)?.i ?? []).map((e) => t?.modules[e]).filter((e) => e !== void 0);
	if (i.length === 0) {
		e.remove();
		return;
	}
	e.hidden = !1;
	let a = e.querySelector("ul");
	if (a) {
		for (let e of [...i].sort((e, t) => e.n.localeCompare(t.n))) {
			let t = document.createElement("li"), n = document.createElement("a");
			n.href = r(e.p), n.textContent = e.n, t.append(n), a.append(t);
		}
		e.querySelector("summary")?.append(O(i.length));
	}
}
//#endregion
//#region src/instances.ts
function A() {
	let e = document.querySelectorAll("[data-fill=\"instances\"], [data-fill=\"instances-for\"], [data-fill=\"used-by\"]");
	for (let t of e) t.addEventListener("toggle", async () => {
		let e = t.querySelector("ul");
		if (!e) return;
		let n = t.dataset.fill ?? "", r = t.dataset.name ?? "", [i, a] = await Promise.all([j(n), D()]), o = i?.[r] ?? [];
		if (e.textContent = "", o.length === 0) {
			let t = document.createElement("li");
			t.className = "search-empty", t.textContent = i ? "None" : "Index unavailable", e.append(t);
			return;
		}
		let s = a ? y(a.index, o) : /* @__PURE__ */ new Map();
		for (let t of o) e.append(M(a, t, s.get(t)));
	}, { once: !0 });
}
async function j(e) {
	if (e === "used-by") return await te();
	let t = await E();
	if (!t) return null;
	let n = e === "instances" ? t.instances : t.instancesFor;
	return n ? { ...n } : {};
}
function M(e, t, n) {
	let i = document.createElement("li"), a = document.createElement("a");
	a.textContent = t;
	let o = e && n !== void 0 ? e.modules[v(e.index, n)] : void 0;
	return a.href = o ? `${r(o.p)}#${t}` : `#${t}`, i.append(a), i;
}
//#endregion
//#region src/result-item.ts
function N(e, t) {
	let n = document.createElement("li"), i = document.createElement("a"), a = g(e.index, t), o = e.modules[v(e.index, t)];
	i.href = o ? `${r(o.p)}#${a}` : `#${a}`;
	let s = document.createElement("span");
	s.className = "kind", s.textContent = _(e.index, t);
	let c = document.createElement("span");
	c.textContent = a;
	let l = document.createElement("span");
	return l.className = "where", l.textContent = o?.n ?? "", i.append(s, c, l), n.append(i), n;
}
//#endregion
//#region src/score.ts
function P(e, t, n, r, i) {
	if (t - n >= i) {
		let a = !0;
		for (let t = 0; t < i; t++) if (e[n + t] !== r[t]) {
			a = !1;
			break;
		}
		if (a) return 3e3 - h(e, n, t);
	}
	if (t < i) return -1;
	let a = !0;
	for (let t = 0; t < i; t++) if (e[t] !== r[t]) {
		a = !1;
		break;
	}
	if (a) return 2e3 - h(e, 0, t);
	for (let n = 1; n <= t - i; n++) {
		let t = !0;
		for (let a = 0; a < i; a++) if (e[n + a] !== r[a]) {
			t = !1;
			break;
		}
		if (t) return 1e3 - h(e, 0, n);
	}
	return -1;
}
function F(e, t) {
	let n = Array.from({ length: t }, (e, t) => t);
	return n.sort((t, n) => e.score[n] - e.score[t] || e.length[t] - e.length[n] || e.id[t] - e.id[n]), n.map((t) => e.id[t]);
}
//#endregion
//#region src/search.ts
function I(e, t) {
	let n = f.encode(t), r = n.length, i = e.narrow;
	if (i && t.startsWith(i.query)) return L(e, i, n, r, t);
	let c = e.bytes, l = e.folds.size > 0, u = {
		names: [],
		starts: [],
		ids: []
	}, d = e.names, m = 0, g = -1;
	for (let t = 0; t < e.count; t++) {
		let i = c[d++], f = c[d++];
		f === 255 && (f = c[d] | c[d + 1] << 8, d += 2), s(i + f);
		for (let e = 0; e < f; e++) {
			let t = c[d + e];
			a[i + e] = t, o[i + e] = p[t];
		}
		d += f;
		let _ = i + f, v = -1;
		for (let e = _ - 1; e >= i; e--) if (o[e] === 46) {
			v = e;
			break;
		}
		if (v < 0) {
			if (g < i) v = g;
			else for (let e = i - 1; e >= 0; e--) if (o[e] === 46) {
				v = e;
				break;
			}
		}
		g = v;
		let y = o, b = _, x = v + 1;
		if (l) {
			let n = e.folds.get(t);
			if (n) {
				y = n, b = n.length, x = 0;
				for (let e = b - 1; e >= 0; e--) if (y[e] === 46) {
					x = e + 1;
					break;
				}
			}
		}
		let S = P(y, b, x, n, r);
		S > 0 && (e.id[m] = t, e.score[m] = S, e.length[m] = h(y, 0, b), m < 512 && (u.names.push(y.slice(0, b)), u.starts.push(x), u.ids.push(t)), m++);
	}
	return e.narrow = m <= 512 ? {
		query: t,
		...u
	} : null, F(e, m);
}
function L(e, t, n, r, i) {
	let a = {
		names: [],
		starts: [],
		ids: []
	}, o = 0;
	for (let i = 0; i < t.ids.length; i++) {
		let s = t.names[i], c = P(s, s.length, t.starts[i], n, r);
		c > 0 && (e.id[o] = t.ids[i], e.score[o] = c, e.length[o] = h(s, 0, s.length), a.names.push(s), a.starts.push(t.starts[i]), a.ids.push(t.ids[i]), o++);
	}
	return e.narrow = {
		query: i,
		...a
	}, F(e, o);
}
//#endregion
//#region src/not-found.ts
var R = 20;
async function z() {
	let e = document.getElementById("how-about"), t = document.getElementById("missing-path");
	if (t && (t.textContent = location.pathname + location.hash), !e) return;
	let n = (decodeURIComponent(location.hash.slice(1)) || decodeURIComponent(location.pathname).replace(/\.html$/, "").split("/").filter(Boolean).join(".")).trim().toLowerCase();
	if (n.length < 2) return;
	let r = await D();
	if (!r) return;
	let i = I(r.index, n).slice(0, R);
	if (i.length !== 0) {
		for (let t of i) e.append(N(r, t));
		document.getElementById("how-about-heading")?.removeAttribute("hidden");
	}
}
//#endregion
//#region src/search-box.ts
var B = 90, V = 30;
function H() {
	let e = document.getElementById("search-input"), t = document.getElementById("search-results");
	if (!e || !t) return;
	let n = [], r = -1, i = 0, a = () => {
		t.hidden = !0, t.textContent = "", n = [], r = -1;
	}, o = async () => {
		let i = e.value.trim().toLowerCase();
		if (i.length < 2) return a();
		let o = await D();
		if (!o) return a();
		let s = I(o.index, i);
		if (t.textContent = "", s.length === 0) {
			let e = document.createElement("li");
			e.className = "search-empty", e.textContent = "No matching declaration", t.append(e), t.hidden = !1;
			return;
		}
		n = s.slice(0, V).map((e) => {
			let n = N(o, e);
			return t.append(n), n;
		}), r = -1, t.hidden = !1;
	}, s = (e) => {
		if (n.length === 0) return;
		n[r]?.removeAttribute("aria-selected"), r = (r + e + n.length) % n.length;
		let t = n[r];
		t && (t.setAttribute("aria-selected", "true"), t.scrollIntoView({ block: "nearest" }));
	};
	e.addEventListener("input", () => {
		clearTimeout(i), i = setTimeout(() => void o(), B);
	}), e.addEventListener("focus", () => void D()), e.addEventListener("keydown", (t) => {
		t.key === "ArrowDown" ? (t.preventDefault(), s(1)) : t.key === "ArrowUp" ? (t.preventDefault(), s(-1)) : t.key === "Escape" ? (a(), e.blur()) : t.key === "Enter" && r >= 0 && (t.preventDefault(), n[r]?.querySelector("a")?.click());
	}), document.addEventListener("click", (e) => {
		e.target?.closest(".search") || a();
	}), document.addEventListener("keydown", (t) => {
		let n = document.activeElement?.tagName;
		t.key === "/" && n !== "INPUT" && n !== "TEXTAREA" && (t.preventDefault(), e.focus(), e.select());
	});
}
//#endregion
//#region src/search-page.ts
var U = 90, W = 200;
function G() {
	let e = document.getElementById("page-results"), t = document.getElementById("page-note"), n = document.getElementById("search-input");
	if (!e || !n) return;
	document.getElementById("search-results")?.remove();
	let r = new URLSearchParams(location.search).get("q");
	r && !n.value && (n.value = r);
	let i = async () => {
		let r = n.value.trim().toLowerCase();
		if (e.textContent = "", r.length < 2) {
			t && (t.textContent = "Type at least two characters.");
			return;
		}
		let i = await D();
		if (!i) {
			t && (t.textContent = "The search index could not be loaded.");
			return;
		}
		let a = I(i.index, r);
		for (let t of a.slice(0, W)) e.append(N(i, t));
		t && (t.textContent = a.length === 0 ? "No matching declaration." : a.length > W ? `${a.length} matches, showing the first ${W}.` : `${a.length} match${a.length === 1 ? "" : "es"}.`);
	}, a = 0;
	n.addEventListener("input", () => {
		clearTimeout(a), a = setTimeout(() => void i(), U);
	}), n.form?.addEventListener("submit", (e) => {
		e.preventDefault(), i();
	}), n.focus(), i();
}
//#endregion
//#region src/sundry.ts
function K() {
	if (new URLSearchParams(location.search).get("jump") !== "src") return;
	let e = document.getElementById(decodeURIComponent(location.hash.slice(1)))?.querySelector(".src")?.href;
	e && location.replace(e);
}
function q() {
	addEventListener("beforeprint", () => {
		for (let e of document.querySelectorAll("details:not([open])")) e.open = !0, e.dataset.printOpened = "1";
	}), addEventListener("afterprint", () => {
		for (let e of document.querySelectorAll("details[data-print-opened]")) e.open = !1, delete e.dataset.printOpened;
	});
}
//#endregion
//#region src/theme-key.ts
var J = "litedoc4-theme", Y = [
	"auto",
	"light",
	"dark"
], X = (e) => e !== null && Y.includes(e);
function Z() {
	try {
		let e = localStorage.getItem(J);
		return X(e) ? e : "auto";
	} catch {
		return "auto";
	}
}
function Q(e) {
	e === "auto" ? delete document.documentElement.dataset.theme : document.documentElement.dataset.theme = e;
	let t = document.getElementById("theme-toggle");
	t && (t.title = `Theme: ${e}`, t.ariaLabel = t.title);
}
function ne() {
	Q(Z()), document.getElementById("theme-toggle")?.addEventListener("click", () => {
		let e = Y[(Y.indexOf(Z()) + 1) % Y.length];
		try {
			localStorage.setItem(J, e);
		} catch {}
		Q(e);
	});
}
//#endregion
//#region src/tree.ts
function re(e) {
	let t = { children: /* @__PURE__ */ new Map() };
	for (let n of e) {
		let e = t;
		for (let t of n.n.split(".")) {
			let n = e.children.get(t);
			n || (n = { children: /* @__PURE__ */ new Map() }, e.children.set(t, n)), e = n;
		}
		e.page = n;
	}
	return t;
}
function $(e, t, n) {
	let i = document.createElement("ul");
	for (let [a, o] of e.children) {
		let e = t ? `${t}.${a}` : a, s = document.createElement("li"), c = document.createElement("div");
		c.className = "row";
		let l = null;
		if (o.children.size > 0) {
			l = $(o, e, n), l.hidden = !(n === e || n.startsWith(`${e}.`));
			let t = document.createElement("button");
			t.type = "button", t.className = "twisty", t.setAttribute("aria-expanded", String(!l.hidden)), t.setAttribute("aria-label", e);
			let r = l;
			t.addEventListener("click", () => {
				r.hidden = !r.hidden, t.setAttribute("aria-expanded", String(!r.hidden));
			}), c.append(t);
		} else {
			let e = document.createElement("span");
			e.className = "twisty-spacer", c.append(e);
		}
		if (o.page) {
			let t = document.createElement("a");
			t.href = r(o.page.p), t.textContent = a, e === n && t.setAttribute("aria-current", "page"), c.append(t);
		} else {
			let e = document.createElement("span");
			e.className = "node-name", e.textContent = a, c.append(e);
		}
		s.append(c), l && s.append(l), i.append(s);
	}
	return i;
}
async function ie() {
	let e = document.getElementById("module-tree");
	if (!e) return;
	let t = await T();
	t?.modules?.length && (e.textContent = "", e.append($(re(t.modules), "", n)), e.querySelector("[aria-current]")?.scrollIntoView({ block: "center" }));
}
ne(), i(), G(), H(), A(), q(), K(), ie(), k(), z();
//#endregion
