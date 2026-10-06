//#region src/scratch.ts
var e = /* @__PURE__ */ new Uint8Array(512), t = /* @__PURE__ */ new Uint8Array(512);
function n(n) {
	if (n <= e.length) return;
	let r = e.length;
	for (; r < n;) r *= 2;
	let i = new Uint8Array(r);
	i.set(e);
	let a = new Uint8Array(r);
	a.set(t), e = i, t = a;
}
//#endregion
//#region src/index-format.ts
var r = 1395934284, i = 2, a = 52, o = new TextDecoder(), s = new TextEncoder(), c = /* @__PURE__ */ new Uint8Array(256);
for (let e = 0; e < 256; e++) c[e] = e >= 65 && e <= 90 ? e + 32 : e;
function l(e) {
	let t = (t) => (e[t] | e[t + 1] << 8 | e[t + 2] << 16) + e[t + 3] * 16777216, n = (t) => e[t] | e[t + 1] << 8;
	if (e.length < a || t(0) !== r || t(4) !== i) return null;
	let s = t(8), c = {
		bytes: e,
		count: s,
		names: t(16),
		restarts: t(24),
		restart: t(12),
		kindOf: t(36),
		moduleOf: t(40),
		labels: [],
		folds: /* @__PURE__ */ new Map(),
		narrow: null,
		score: new Uint16Array(s),
		length: new Uint16Array(s),
		id: s < 65536 ? new Uint16Array(s) : new Uint32Array(s)
	}, l = t(28), u = l + 4;
	for (let n = 0, r = t(l); n < r; n++) {
		let t = e[u];
		c.labels.push(o.decode(e.subarray(u + 1, u + 1 + t))), u += 1 + t;
	}
	let d = t(44);
	u = d + 4;
	for (let r = 0, i = t(d); r < i; r++) {
		let r = n(u + 4);
		c.folds.set(t(u), e.subarray(u + 6, u + 6 + r)), u += 6 + r;
	}
	return c;
}
function u(e, t, n) {
	let r = 0;
	for (let i = t; i < n; i++) {
		let t = e[i];
		(t & 192) != 128 && (r += t >= 240 ? 2 : 1);
	}
	return r;
}
function d(e, t) {
	let n = e.bytes, r = Math.floor(t / e.restart), i = e.restarts + r * 4, a = e.names + ((n[i] | n[i + 1] << 8 | n[i + 2] << 16) + n[i + 3] * 16777216), s = /* @__PURE__ */ new Uint8Array(256), c = 0;
	for (let i = r * e.restart; i <= t; i++) {
		let e = n[a++], t = n[a++];
		if (t === 255 && (t = n[a] | n[a + 1] << 8, a += 2), e + t > s.length) {
			let n = new Uint8Array(Math.max(e + t, s.length * 2));
			n.set(s), s = n;
		}
		s.set(n.subarray(a, a + t), e), a += t, c = e + t;
	}
	return o.decode(s.subarray(0, c));
}
var f = (e, t) => e.labels[e.bytes[e.kindOf + t]] ?? "", p = (e, t) => e.bytes[e.moduleOf + t * 2] | e.bytes[e.moduleOf + t * 2 + 1] << 8;
function m(t, r) {
	let i = new Set(r), a = /* @__PURE__ */ new Map(), s = t.bytes, c = t.names;
	for (let r = 0; r < t.count && a.size < i.size; r++) {
		let t = s[c++], l = s[c++];
		l === 255 && (l = s[c] | s[c + 1] << 8, c += 2), n(t + l), e.set(s.subarray(c, c + l), t), c += l;
		let u = o.decode(e.subarray(0, t + l));
		i.has(u) && a.set(u, r);
	}
	return a;
}
//#endregion
//#region src/site.ts
var h = document.body, g = h.dataset.root ?? "./", _ = h.dataset.module ?? "", v = (e) => new URL(g + e, location.href).href, y = null, b = null, x = null, S = null, C = (e) => fetch(v(e)).then((e) => e.ok ? e.json() : Promise.reject(Error(String(e.status)))).catch(() => null);
function w() {
	return y ??= C("modules.json"), y;
}
function T() {
	return b ??= fetch(v("search-index.bin")).then((e) => e.ok ? e.arrayBuffer() : Promise.reject(Error(String(e.status)))).then((e) => l(new Uint8Array(e))).catch(() => null), b;
}
function E() {
	return x ??= C("instances.json"), x;
}
function D() {
	return S ??= C("declarations/used-by.json"), S;
}
async function O() {
	let [e, t] = await Promise.all([w(), T()]);
	return !e?.modules || !t ? null : {
		modules: e.modules,
		index: t
	};
}
var k = {
	data: O,
	href: v
};
//#endregion
//#region src/drawer.ts
function A() {
	let e = document.getElementById("nav-toggle"), t = document.getElementById("scrim");
	if (!e) return;
	let n = (n) => {
		h.dataset.nav = n ? "open" : "closed", e.setAttribute("aria-expanded", String(n)), t && (t.hidden = !n);
	};
	n(!1), e.addEventListener("click", () => n(h.dataset.nav !== "open")), t?.addEventListener("click", () => n(!1)), document.addEventListener("keydown", (e) => {
		e.key === "Escape" && h.dataset.nav === "open" && n(!1);
	}), document.getElementById("sidebar")?.addEventListener("click", (e) => {
		e.target?.closest("a") && n(!1);
	});
}
//#endregion
//#region src/imported-by.ts
function j(e) {
	let t = document.createElement("span");
	return t.className = "count", t.textContent = ` ${e}`, t;
}
async function M() {
	let e = document.querySelector("[data-fill=\"imported-by\"]");
	if (!e) return;
	let t = await w(), n = (t?.modules?.find((e) => e.n === _)?.i ?? []).map((e) => t?.modules[e]).filter((e) => e !== void 0);
	if (n.length === 0) {
		e.remove();
		return;
	}
	e.hidden = !1;
	let r = e.querySelector("ul");
	if (r) {
		for (let e of [...n].sort((e, t) => e.n.localeCompare(t.n))) {
			let t = document.createElement("li"), n = document.createElement("a");
			n.href = v(e.p), n.textContent = e.n, t.append(n), r.append(t);
		}
		e.querySelector("summary")?.append(j(n.length));
	}
}
//#endregion
//#region src/instances.ts
function N() {
	let e = document.querySelectorAll("[data-fill=\"instances\"], [data-fill=\"instances-for\"], [data-fill=\"used-by\"]");
	for (let t of e) t.addEventListener("toggle", async () => {
		let e = t.querySelector("ul");
		if (!e) return;
		let n = t.dataset.fill ?? "", r = t.dataset.name ?? "", [i, a] = await Promise.all([P(n), O()]), o = i?.[r] ?? [];
		if (e.textContent = "", o.length === 0) {
			let t = document.createElement("li");
			t.className = "search-empty", t.textContent = i ? "None" : "Index unavailable", e.append(t);
			return;
		}
		let s = a ? m(a.index, o) : /* @__PURE__ */ new Map();
		for (let t of o) e.append(F(a, t, s.get(t), v));
	}, { once: !0 });
}
async function P(e) {
	if (e === "used-by") return await D();
	let t = await E();
	if (!t) return null;
	let n = e === "instances" ? t.instances : t.instancesFor;
	return n ? { ...n } : {};
}
function F(e, t, n, r) {
	let i = document.createElement("li"), a = document.createElement("a");
	a.textContent = t;
	let o = e && n !== void 0 ? e.modules[p(e.index, n)] : void 0;
	return a.href = o ? `${r(o.p)}#${t}` : `#${t}`, i.append(a), i;
}
//#endregion
//#region src/result-item.ts
function I(e, t, n) {
	let r = document.createElement("li"), i = document.createElement("a"), a = d(e.index, t), o = e.modules[p(e.index, t)];
	i.href = o ? `${n(o.p)}#${a}` : `#${a}`;
	let s = document.createElement("span");
	s.className = "kind", s.textContent = f(e.index, t);
	let c = document.createElement("span");
	c.textContent = a;
	let l = document.createElement("span");
	return l.className = "where", l.textContent = o?.n ?? "", i.append(s, c, l), r.append(i), r;
}
//#endregion
//#region src/score.ts
function L(e, t, n, r, i) {
	if (t - n >= i) {
		let a = !0;
		for (let t = 0; t < i; t++) if (e[n + t] !== r[t]) {
			a = !1;
			break;
		}
		if (a) return 3e3 - u(e, n, t);
	}
	if (t < i) return -1;
	let a = !0;
	for (let t = 0; t < i; t++) if (e[t] !== r[t]) {
		a = !1;
		break;
	}
	if (a) return 2e3 - u(e, 0, t);
	for (let n = 1; n <= t - i; n++) {
		let t = !0;
		for (let a = 0; a < i; a++) if (e[n + a] !== r[a]) {
			t = !1;
			break;
		}
		if (t) return 1e3 - u(e, 0, n);
	}
	return -1;
}
function R(e, t) {
	let n = Array.from({ length: t }, (e, t) => t);
	return n.sort((t, n) => e.score[n] - e.score[t] || e.length[t] - e.length[n] || e.id[t] - e.id[n]), n.map((t) => e.id[t]);
}
//#endregion
//#region src/search.ts
function z(r, i) {
	let a = s.encode(i), o = a.length, l = r.narrow;
	if (l && i.startsWith(l.query)) return B(r, l, a, o, i);
	let d = r.bytes, f = r.folds.size > 0, p = {
		names: [],
		starts: [],
		ids: []
	}, m = r.names, h = 0, g = -1;
	for (let i = 0; i < r.count; i++) {
		let s = d[m++], l = d[m++];
		l === 255 && (l = d[m] | d[m + 1] << 8, m += 2), n(s + l);
		for (let n = 0; n < l; n++) {
			let r = d[m + n];
			e[s + n] = r, t[s + n] = c[r];
		}
		m += l;
		let _ = s + l, v = -1;
		for (let e = _ - 1; e >= s; e--) if (t[e] === 46) {
			v = e;
			break;
		}
		if (v < 0) {
			if (g < s) v = g;
			else for (let e = s - 1; e >= 0; e--) if (t[e] === 46) {
				v = e;
				break;
			}
		}
		g = v;
		let y = t, b = _, x = v + 1;
		if (f) {
			let e = r.folds.get(i);
			if (e) {
				y = e, b = e.length, x = 0;
				for (let e = b - 1; e >= 0; e--) if (y[e] === 46) {
					x = e + 1;
					break;
				}
			}
		}
		let S = L(y, b, x, a, o);
		S > 0 && (r.id[h] = i, r.score[h] = S, r.length[h] = u(y, 0, b), h < 512 && (p.names.push(y.slice(0, b)), p.starts.push(x), p.ids.push(i)), h++);
	}
	return r.narrow = h <= 512 ? {
		query: i,
		...p
	} : null, R(r, h);
}
function B(e, t, n, r, i) {
	let a = {
		names: [],
		starts: [],
		ids: []
	}, o = 0;
	for (let i = 0; i < t.ids.length; i++) {
		let s = t.names[i], c = L(s, s.length, t.starts[i], n, r);
		c > 0 && (e.id[o] = t.ids[i], e.score[o] = c, e.length[o] = u(s, 0, s.length), a.names.push(s), a.starts.push(t.starts[i]), a.ids.push(t.ids[i]), o++);
	}
	return e.narrow = {
		query: i,
		...a
	}, R(e, o);
}
//#endregion
//#region src/not-found.ts
var V = 20;
async function H() {
	let e = document.getElementById("how-about"), t = document.getElementById("missing-path");
	if (t && (t.textContent = location.pathname + location.hash), !e) return;
	let n = (decodeURIComponent(location.hash.slice(1)) || decodeURIComponent(location.pathname).replace(/\.html$/, "").split("/").filter(Boolean).join(".")).trim().toLowerCase();
	if (n.length < 2) return;
	let r = await O();
	if (!r) return;
	let i = z(r.index, n).slice(0, V);
	if (i.length !== 0) {
		for (let t of i) e.append(I(r, t, v));
		document.getElementById("how-about-heading")?.removeAttribute("hidden");
	}
}
//#endregion
//#region src/search-box.ts
var U = 90, W = 30;
function G(e) {
	let t = document.getElementById("search-input"), n = document.getElementById("search-results");
	if (!t || !n) return;
	let r = [], i = -1, a = 0, o = () => {
		n.hidden = !0, n.textContent = "", r = [], i = -1;
	}, s = async () => {
		let a = t.value.trim().toLowerCase();
		if (a.length < 2) return o();
		let s = await e.data();
		if (!s) return o();
		let c = z(s.index, a);
		if (n.textContent = "", c.length === 0) {
			let e = document.createElement("li");
			e.className = "search-empty", e.textContent = "No matching declaration", n.append(e), n.hidden = !1;
			return;
		}
		r = c.slice(0, W).map((t) => {
			let r = I(s, t, e.href);
			return n.append(r), r;
		}), i = -1, n.hidden = !1;
	}, c = (e) => {
		if (r.length === 0) return;
		r[i]?.removeAttribute("aria-selected"), i = (i + e + r.length) % r.length;
		let t = r[i];
		t && (t.setAttribute("aria-selected", "true"), t.scrollIntoView({ block: "nearest" }));
	};
	t.addEventListener("input", () => {
		clearTimeout(a), a = setTimeout(() => void s(), U);
	}), t.addEventListener("focus", () => void e.data()), t.addEventListener("keydown", (e) => {
		e.key === "ArrowDown" ? (e.preventDefault(), c(1)) : e.key === "ArrowUp" ? (e.preventDefault(), c(-1)) : e.key === "Escape" ? (o(), t.blur()) : e.key === "Enter" && i >= 0 && (e.preventDefault(), r[i]?.querySelector("a")?.click());
	}), document.addEventListener("click", (e) => {
		e.target?.closest(".search") || o();
	}), document.addEventListener("keydown", (e) => {
		let n = document.activeElement?.tagName;
		e.key === "/" && n !== "INPUT" && n !== "TEXTAREA" && (e.preventDefault(), t.focus(), t.select());
	});
}
//#endregion
//#region src/search-page.ts
var K = 90, q = 200;
function J(e) {
	let t = document.getElementById("page-results"), n = document.getElementById("page-note"), r = document.getElementById("search-input");
	if (!t || !r) return;
	document.getElementById("search-results")?.remove();
	let i = new URLSearchParams(location.search).get("q");
	i && !r.value && (r.value = i);
	let a = async () => {
		let i = r.value.trim().toLowerCase();
		if (t.textContent = "", i.length < 2) {
			n && (n.textContent = "Type at least two characters.");
			return;
		}
		let a = await e.data();
		if (!a) {
			n && (n.textContent = "The search index could not be loaded.");
			return;
		}
		let o = z(a.index, i);
		for (let n of o.slice(0, q)) t.append(I(a, n, e.href));
		n && (n.textContent = o.length === 0 ? "No matching declaration." : o.length > q ? `${o.length} matches, showing the first ${q}.` : `${o.length} match${o.length === 1 ? "" : "es"}.`);
	}, o = 0;
	r.addEventListener("input", () => {
		clearTimeout(o), o = setTimeout(() => void a(), K);
	}), r.form?.addEventListener("submit", (e) => {
		e.preventDefault(), a();
	}), r.focus(), a();
}
//#endregion
//#region src/sundry.ts
function ee() {
	if (new URLSearchParams(location.search).get("jump") !== "src") return;
	let e = document.getElementById(decodeURIComponent(location.hash.slice(1)))?.querySelector(".src")?.href;
	e && location.replace(e);
}
function te() {
	addEventListener("beforeprint", () => {
		for (let e of document.querySelectorAll("details:not([open])")) e.open = !0, e.dataset.printOpened = "1";
	}), addEventListener("afterprint", () => {
		for (let e of document.querySelectorAll("details[data-print-opened]")) e.open = !1, delete e.dataset.printOpened;
	});
}
//#endregion
//#region src/theme-key.ts
var Y = "litedoc4-theme", X = [
	"auto",
	"light",
	"dark"
], ne = (e) => e !== null && X.includes(e);
function Z() {
	try {
		let e = localStorage.getItem(Y);
		return ne(e) ? e : "auto";
	} catch {
		return "auto";
	}
}
function Q(e) {
	e === "auto" ? delete document.documentElement.dataset.theme : document.documentElement.dataset.theme = e;
	let t = document.getElementById("theme-toggle");
	t && (t.title = `Theme: ${e}`, t.ariaLabel = t.title);
}
function re() {
	Q(Z()), document.getElementById("theme-toggle")?.addEventListener("click", () => {
		let e = X[(X.indexOf(Z()) + 1) % X.length];
		try {
			localStorage.setItem(Y, e);
		} catch {}
		Q(e);
	});
}
//#endregion
//#region src/tree.ts
function ie(e) {
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
function $(e, t, n, r) {
	let i = document.createElement("ul");
	for (let [a, o] of e.children) {
		let e = t ? `${t}.${a}` : a, s = document.createElement("li"), c = document.createElement("div");
		c.className = "row";
		let l = null;
		if (o.children.size > 0) {
			l = $(o, e, n, r), l.hidden = !(n === e || n.startsWith(`${e}.`));
			let t = document.createElement("button");
			t.type = "button", t.className = "twisty", t.setAttribute("aria-expanded", String(!l.hidden)), t.setAttribute("aria-label", e);
			let i = l;
			t.addEventListener("click", () => {
				i.hidden = !i.hidden, t.setAttribute("aria-expanded", String(!i.hidden));
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
async function ae() {
	let e = document.getElementById("module-tree");
	if (!e) return;
	let t = await w();
	t?.modules?.length && (e.textContent = "", e.append($(ie(t.modules), "", _, v)), e.querySelector("[aria-current]")?.scrollIntoView({ block: "center" }));
}
re(), A(), J(k), G(k), N(), te(), ee(), ae(), M(), H();
//#endregion
