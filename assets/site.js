//#region src/site.ts
var e = document.body;
e.dataset.root, e.dataset.module;
//#endregion
//#region src/drawer.ts
function t(t = new AbortController().signal) {
	let n = document.getElementById("nav-toggle"), r = document.getElementById("scrim");
	if (!n) return;
	let i = (t) => {
		e.dataset.nav = t ? "open" : "closed", n.setAttribute("aria-expanded", String(t)), r && (r.hidden = !t);
	};
	i(!1), n.addEventListener("click", () => i(e.dataset.nav !== "open")), r?.addEventListener("click", () => i(!1)), document.addEventListener("keydown", (t) => {
		t.key === "Escape" && e.dataset.nav === "open" && i(!1);
	}, { signal: t }), document.getElementById("sidebar")?.addEventListener("click", (e) => {
		e.target?.closest("a") && i(!1);
	});
}
//#endregion
//#region src/hash-route.ts
var n = "id", r = (e) => {
	try {
		return decodeURIComponent(e);
	} catch {
		return e;
	}
}, i = (e, t) => {
	let n = e.indexOf(t);
	return n < 0 ? [e, null] : [e.slice(0, n), e.slice(n + 1)];
};
function a(e, t) {
	let [r, a] = i(t, "#"), [o, s] = i(r, "?"), c = new URLSearchParams(s ?? "");
	a !== null && c.set(n, a);
	let l = o === "index.html" ? "" : o.replace(/\.html$/, ""), u = c.toString();
	return `#/${e}/${l}${u ? `?${u}` : ""}`;
}
function o(e) {
	if (!e.startsWith("#/")) return null;
	let [t, a] = i(e.slice(2), "?"), o = new URLSearchParams(a ?? ""), s = o.get(n);
	o.delete(n);
	let c = o.toString(), [l, u] = i(r(t), "/");
	return l === "" ? null : {
		version: l,
		page: u ?? "",
		query: c ? `?${c}` : "",
		anchor: s
	};
}
//#endregion
//#region src/scratch.ts
var s = /* @__PURE__ */ new Uint8Array(512), c = /* @__PURE__ */ new Uint8Array(512);
function l(e) {
	if (e <= s.length) return;
	let t = s.length;
	for (; t < e;) t *= 2;
	let n = new Uint8Array(t);
	n.set(s);
	let r = new Uint8Array(t);
	r.set(c), s = n, c = r;
}
//#endregion
//#region src/index-format.ts
var u = 1395934284, d = 2, f = 52, p = new TextDecoder(), m = new TextEncoder(), ee = /* @__PURE__ */ new Uint8Array(256);
for (let e = 0; e < 256; e++) ee[e] = e >= 65 && e <= 90 ? e + 32 : e;
function h(e) {
	let t = (t) => (e[t] | e[t + 1] << 8 | e[t + 2] << 16) + e[t + 3] * 16777216, n = (t) => e[t] | e[t + 1] << 8;
	if (e.length < f || t(0) !== u || t(4) !== d) return null;
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
		i.labels.push(p.decode(e.subarray(o + 1, o + 1 + t))), o += 1 + t;
	}
	let s = t(44);
	o = s + 4;
	for (let r = 0, a = t(s); r < a; r++) {
		let r = n(o + 4);
		i.folds.set(t(o), e.subarray(o + 6, o + 6 + r)), o += 6 + r;
	}
	return i;
}
function g(e, t, n) {
	let r = 0;
	for (let i = t; i < n; i++) {
		let t = e[i];
		(t & 192) != 128 && (r += t >= 240 ? 2 : 1);
	}
	return r;
}
function _(e, t) {
	let n = e.bytes, r = Math.floor(t / e.restart), i = e.restarts + r * 4, a = e.names + ((n[i] | n[i + 1] << 8 | n[i + 2] << 16) + n[i + 3] * 16777216), o = /* @__PURE__ */ new Uint8Array(256), s = 0;
	for (let i = r * e.restart; i <= t; i++) {
		let e = n[a++], t = n[a++];
		if (t === 255 && (t = n[a] | n[a + 1] << 8, a += 2), e + t > o.length) {
			let n = new Uint8Array(Math.max(e + t, o.length * 2));
			n.set(o), o = n;
		}
		o.set(n.subarray(a, a + t), e), a += t, s = e + t;
	}
	return p.decode(o.subarray(0, s));
}
var v = (e, t) => e.labels[e.bytes[e.kindOf + t]] ?? "", y = (e, t) => e.bytes[e.moduleOf + t * 2] | e.bytes[e.moduleOf + t * 2 + 1] << 8;
function b(e, t) {
	let n = new Set(t), r = /* @__PURE__ */ new Map(), i = e.bytes, a = e.names;
	for (let t = 0; t < e.count && r.size < n.size; t++) {
		let e = i[a++], o = i[a++];
		o === 255 && (o = i[a] | i[a + 1] << 8, a += 2), l(e + o), s.set(i.subarray(a, a + o), e), a += o;
		let c = p.decode(s.subarray(0, e + o));
		n.has(c) && r.set(c, t);
	}
	return r;
}
//#endregion
//#region src/result-item.ts
function x(e, t, n) {
	let r = document.createElement("li"), i = document.createElement("a"), a = _(e.index, t), o = e.modules[y(e.index, t)];
	i.href = o ? n(`${o.p}#${a}`) : `#${a}`;
	let s = document.createElement("span");
	s.className = "kind", s.textContent = v(e.index, t);
	let c = document.createElement("span");
	c.textContent = a;
	let l = document.createElement("span");
	return l.className = "where", l.textContent = o?.n ?? "", i.append(s, c, l), r.append(i), r;
}
//#endregion
//#region src/score.ts
function te(e, t, n, r, i) {
	if (t - n >= i) {
		let a = !0;
		for (let t = 0; t < i; t++) if (e[n + t] !== r[t]) {
			a = !1;
			break;
		}
		if (a) return 3e3 - g(e, n, t);
	}
	if (t < i) return -1;
	let a = !0;
	for (let t = 0; t < i; t++) if (e[t] !== r[t]) {
		a = !1;
		break;
	}
	if (a) return 2e3 - g(e, 0, t);
	for (let n = 1; n <= t - i; n++) {
		let t = !0;
		for (let a = 0; a < i; a++) if (e[n + a] !== r[a]) {
			t = !1;
			break;
		}
		if (t) return 1e3 - g(e, 0, n);
	}
	return -1;
}
function ne(e, t) {
	let n = Array.from({ length: t }, (e, t) => t);
	return n.sort((t, n) => e.score[n] - e.score[t] || e.length[t] - e.length[n] || e.id[t] - e.id[n]), n.map((t) => e.id[t]);
}
//#endregion
//#region src/search.ts
function S(e, t) {
	let n = m.encode(t), r = n.length, i = e.narrow;
	if (i && t.startsWith(i.query)) return re(e, i, n, r, t);
	let a = e.bytes, o = e.folds.size > 0, u = {
		names: [],
		starts: [],
		ids: []
	}, d = e.names, f = 0, p = -1;
	for (let t = 0; t < e.count; t++) {
		let i = a[d++], m = a[d++];
		m === 255 && (m = a[d] | a[d + 1] << 8, d += 2), l(i + m);
		for (let e = 0; e < m; e++) {
			let t = a[d + e];
			s[i + e] = t, c[i + e] = ee[t];
		}
		d += m;
		let h = i + m, _ = -1;
		for (let e = h - 1; e >= i; e--) if (c[e] === 46) {
			_ = e;
			break;
		}
		if (_ < 0) {
			if (p < i) _ = p;
			else for (let e = i - 1; e >= 0; e--) if (c[e] === 46) {
				_ = e;
				break;
			}
		}
		p = _;
		let v = c, y = h, b = _ + 1;
		if (o) {
			let n = e.folds.get(t);
			if (n) {
				v = n, y = n.length, b = 0;
				for (let e = y - 1; e >= 0; e--) if (v[e] === 46) {
					b = e + 1;
					break;
				}
			}
		}
		let x = te(v, y, b, n, r);
		x > 0 && (e.id[f] = t, e.score[f] = x, e.length[f] = g(v, 0, y), f < 512 && (u.names.push(v.slice(0, y)), u.starts.push(b), u.ids.push(t)), f++);
	}
	return e.narrow = f <= 512 ? {
		query: t,
		...u
	} : null, ne(e, f);
}
function re(e, t, n, r, i) {
	let a = {
		names: [],
		starts: [],
		ids: []
	}, o = 0;
	for (let i = 0; i < t.ids.length; i++) {
		let s = t.names[i], c = te(s, s.length, t.starts[i], n, r);
		c > 0 && (e.id[o] = t.ids[i], e.score[o] = c, e.length[o] = g(s, 0, s.length), a.names.push(s), a.starts.push(t.starts[i]), a.ids.push(t.ids[i]), o++);
	}
	return e.narrow = {
		query: i,
		...a
	}, ne(e, o);
}
//#endregion
//#region src/guess.ts
var ie = 20;
async function ae(e, t) {
	let n = document.getElementById("how-about"), r = t.trim().toLowerCase();
	if (!n || r.length < 2) return;
	let i = await e.data();
	if (!i) return;
	let a = S(i.index, r).slice(0, ie);
	if (a.length !== 0) {
		for (let t of a) n.append(x(i, t, e.href));
		document.getElementById("how-about-heading")?.removeAttribute("hidden");
	}
}
//#endregion
//#region src/lost.ts
var C = "missing";
//#endregion
//#region src/dom.ts
function w(e, t, ...n) {
	let r = document.createElement(e);
	return t && (r.className = t), r.append(...n), r;
}
function T(e, t, ...n) {
	let r = w("a", e, ...n);
	return r.setAttribute("href", t), r;
}
function E(e, t) {
	return e.id = t, e;
}
function D(e) {
	let t = [];
	return e.split(".").forEach((e, n) => {
		n > 0 && t.push(document.createTextNode(".")), t.push(w("span", "name", e));
	}), t;
}
function O(e) {
	let t = document.createElement("template");
	return t.innerHTML = e, t.content;
}
//#endregion
//#region src/names.ts
var oe = (e) => e.length >= 2 && e.startsWith("«") && e.endsWith("»") ? e.slice(1, -1) : e;
function se(e) {
	let t = [], n = 0, r = 0;
	for (let i = 0; i < e.length; i++) {
		let a = e[i];
		a === "«" ? n++ : a === "»" ? n-- : a === "." && n === 0 && (t.push(oe(e.slice(r, i))), r = i + 1);
	}
	return t.push(oe(e.slice(r))), t;
}
var ce = (e) => se(e).join("/"), le = (e) => `${ce(e)}.html`, k = (e, t) => `${e}/${ce(t)}.lean`, ue = (e, t, n) => k(e, t) + (n ? `#L${n[0]}-L${n[1]}` : ""), A = (e) => e.slice(e.lastIndexOf(".") + 1);
function de(e, t) {
	let n = (e) => t.includes(e);
	if (e === "definition" || e === "instance") {
		let t = n("unsafe") ? "unsafe " : "", r = n("noncomputable") ? "noncomputable " : "", i = e === "instance" ? "instance" : n("abbrev") ? "abbrev" : "def";
		return t + r + i;
	}
	return e === "axiom" && n("unsafe") ? "unsafe axiom" : e === "opaque" && n("partial") ? "partial def" : e === "opaque" && n("unsafe") ? "unsafe opaque" : e === "inductive" && n("unsafe") ? "unsafe inductive" : e === "class_inductive" ? "class inductive" : e;
}
function fe(e) {
	return e === "definition" ? "def" : e === "class_inductive" ? "class" : e === "constructor" ? "ctor" : e;
}
var pe = (e) => String(e).replace(/\B(?=(\d{3})+$)/g, ","), j = "foundational_types.html", M = (e, t, n) => e.at(le(t) + (n === null ? "" : `#${n}`)), me = (e) => typeof e[0] == "number";
function he(e, t, n) {
	if (me(n)) {
		let t = e.bases[e.roots[n[0]] ?? ""];
		return t === void 0 ? null : ue(t, n[1], n.length === 4 ? [n[2], n[3]] : null);
	}
	let r = n;
	return M(e, r[0], r.length === 1 ? t : r[1]);
}
function N(e, t, n) {
	if (!Object.hasOwn(t, n)) return null;
	let r = t[n];
	return r === void 0 ? null : he(e, n, r);
}
//#endregion
//#region src/spans.ts
var ge = (e) => typeof e == "string" ? [e, []] : e;
function _e(e, t, n) {
	let r = t.map(() => []), i = [], a = [];
	t.forEach((e, n) => {
		for (; a.length > 0 && e[0] >= (t[a[a.length - 1] ?? 0]?.[1] ?? 0);) a.pop();
		let o = a[a.length - 1];
		o === void 0 ? i.push(n) : r[o]?.push(n), a.push(n);
	});
	let o = t.map(() => null), s = t.map(() => !1);
	for (let e = t.length - 1; e >= 0; e--) {
		let i = (r[e] ?? []).some((e) => s[e]), a = t[e], c = i || a === void 0 ? null : n(a);
		o[e] = c, s[e] = i || c !== null;
	}
	let c = [], l = (t, n) => {
		if (n <= t) return;
		let r = c[c.length - 1];
		r && r.href === null ? c[c.length - 1] = {
			text: r.text + e.slice(t, n),
			href: null
		} : c.push({
			text: e.slice(t, n),
			href: null
		});
	}, u = (n, i, a) => {
		let s = n;
		for (let n of a) {
			let i = t[n];
			if (i === void 0) continue;
			l(s, i[0]);
			let a = o[n] ?? null;
			a === null ? u(i[0], i[1], r[n] ?? []) : c.push({
				text: e.slice(i[0], i[1]),
				href: a
			}), s = i[1];
		}
		l(s, i);
	};
	return u(0, e.length, i), c;
}
//#endregion
//#region src/words.ts
function ve(e, t) {
	let n = t(e);
	if (n !== null) return {
		before: "",
		linked: e,
		href: n
	};
	let r = e.lastIndexOf(".");
	if (r >= 0) {
		let n = e.slice(r + 1), i = t(n);
		if (i !== null) return {
			before: e.slice(0, r + 1),
			linked: n,
			href: i
		};
	}
	return {
		before: e,
		linked: "",
		href: null
	};
}
function ye(e, t, n) {
	if (e.startsWith("##")) {
		let r = e.slice(2);
		return n(r) ?? t.at(`search.html?q=${encodeURIComponent(r)}`);
	}
	return e.startsWith("#") ? t.here(e.slice(1)) : e.startsWith("http") ? e : t.at(e);
}
function be(e, t, n) {
	let r = (e) => N(n, t, e), i = O(e);
	for (let e of i.querySelectorAll("a[href]")) e.setAttribute("href", ye(e.getAttribute("href") ?? "", n, r));
	for (let e of [...i.querySelectorAll("w")]) {
		let t = ve(e.textContent ?? "", r), n = [];
		t.before && n.push(document.createTextNode(t.before)), t.href !== null && n.push(T("", t.href, t.linked)), e.replaceWith(...n);
	}
	return i;
}
//#endregion
//#region src/draw-module.ts
function P(e, t) {
	let [n, r] = ge(t);
	return _e(n, r, (t) => t.length === 2 ? e.l.at(j) : N(e.l, e.page.names, t[2])).map((e) => e.href === null ? document.createTextNode(e.text) : T("", e.href, e.text));
}
var F = (e, t) => be(t, e.page.words, e.l);
function xe(e, t) {
	return (t ?? []).flatMap(([t, n]) => [w("span", t ? "binder implicit" : "binder", w("span", "fn", ...P(e, n))), document.createTextNode("\n")]);
}
function Se(e, t) {
	let n = w("div", "sig", ...xe(e, t.b));
	return (t.k === "structure" || t.k === "class") && t.p && t.p.length > 0 && (n.append(w("span", "extends", "extends"), " "), t.p.forEach(([t, r], i) => {
		i > 0 && n.append(", "), n.append(E(w("span", "", ...P(e, r)), t));
	})), n.append(w("span", "colon", " :"), w("div", "sig-type", ...P(e, t.t))), n;
}
function Ce(e, t, n) {
	let r = n ? `#L${n[0]}-L${n[1]}` : "";
	return w("header", "decl-head", w("span", "kind", de(t.k, t.mods ?? [])), w("h2", "decl-name", T("break_within", M(e.l, e.page.module, t.n), ...D(t.n))), T("src", e.sourceUrl + r, "source"));
}
function I(e, ...t) {
	let n = w("span", "flag", ...t);
	return n.dataset.flag = e, n;
}
function we(e, t) {
	let n = [];
	if (t.sorry === "direct" && n.push(I("sorry-direct", "uses ", w("code", "", "sorry"))), t.sorry === "transitive" && n.push(I("sorry-transitive", "depends on ", w("code", "", "sorry"))), t.gen) {
		let [r, i] = t.gen, a = N(e.l, e.page.names, i), o = w("code", "", i);
		n.push(I("generated", "realized by ", w("code", "", `@[${r}]`), " from ", a === null ? o : T("", a, o)));
	}
	return n.length === 0 ? null : w("div", "flags", ...n);
}
function L(e, t, n) {
	let r = w("details", "extra", w("summary", "", n), w("ul", ""));
	return r.dataset.fill = e, r.dataset.name = t, r;
}
function Te(e, t) {
	if (!t.eq && !t.eqOmitted) return null;
	let n = w("ul", "equations");
	t.eqOmitted && n.append(w("li", "", "One or more equations did not get rendered due to their size."));
	for (let r of t.eq ?? []) n.append(w("li", "", ...P(e, r)));
	return w("details", "extra", w("summary", "", "Equations"), n);
}
function R(e, t, n) {
	return w("div", "field-sig", t, ...xe(e, n.b), w("span", "colon", " : "), ...P(e, n.t));
}
function Ee(e, t, n) {
	return n.doc && t.append(w("div", "field-doc", F(e, n.doc))), t;
}
function De(e, t, n) {
	let r = A(n.n);
	if (!n.inh) return Ee(e, E(w("li", "field", R(e, w("span", "field-name", r), n)), n.n), n);
	let i = N(e.l, e.page.names, n.n), a = w("li", "field inherited", R(e, i === null ? w("span", "field-name", r) : T("field-name", i, r), n));
	return n.id && (a.id = `${t.n}.${r}`), a;
}
function Oe(e, t) {
	let n = t.ctor ?? `${t.n}.mk`, r = A(n), i = [];
	return r !== "mk" && i.push(w("p", "ctor-note", "constructor ", w("code", "", r))), i.push(E(w("ul", "fields", ...(t.f ?? []).map((n) => De(e, t, n))), n)), i;
}
function ke(e, t) {
	let n = t.c ?? [];
	return n.length === 0 ? [] : [w("ul", "ctors", ...n.map((t) => Ee(e, E(w("li", "ctor", R(e, w("span", "field-name", A(t.n)), t)), t.n), t)))];
}
function Ae(e, t, n) {
	let r = E(w("section", "decl"), t.n);
	r.dataset.kind = fe(t.k), r.append(Ce(e, t, n));
	let i = we(e, t);
	i && r.append(i), t.attrs && t.attrs.length > 0 && r.append(w("div", "attrs", `@[${t.attrs.join(", ")}]`)), r.append(Se(e, t)), t.doc && r.append(w("div", "doc", F(e, t.doc)));
	let a = [], o = () => {
		let n = Te(e, t);
		n && a.push(n);
	};
	return t.k === "structure" || t.k === "class" ? (r.append(...Oe(e, t)), a.push(t.k === "class" ? L("instances", t.n, "Instances") : L("instances-for", t.n, "Instances For"))) : t.k === "definition" ? (o(), a.push(L("instances-for", t.n, "Instances For"))) : t.k === "instance" ? o() : t.k === "inductive" ? (r.append(...ke(e, t)), a.push(L("instances-for", t.n, "Instances For"))) : t.k === "class_inductive" && (r.append(...ke(e, t)), a.push(L("instances", t.n, "Instances"))), a.push(L("used-by", t.n, "Used by")), r.append(...a), r;
}
function je(e, t) {
	let n = e.l.bases[se(t)[0] ?? ""];
	return w("li", "", n === void 0 ? t : T("", k(n, t), t));
}
function Me(e) {
	let t = e.page.imports, n = w("summary", "", "Imports");
	t.length > 0 && n.append(" ", w("span", "count", String(t.length)));
	let r = w("details", "imports", n, w("ul", "", ...t.map((t) => je(e, t)))), i = w("details", "imports", w("summary", "", "Imported by"), w("ul", ""));
	return i.dataset.fill = "imported-by", i.hidden = !0, w("div", "modmeta", r, i);
}
var Ne = (e) => "moddoc" in e;
function Pe(e) {
	return e.flatMap((e) => Ne(e) ? [] : [e.n]);
}
function Fe(e) {
	let t = e.page.module, n = k(e.version.source, t), r = {
		l: e.linker,
		page: e.page,
		sourceUrl: n
	}, i = w("main", "content", w("div", "modhead", w("h1", "", ...D(t)), w("p", "modactions", T("src", n, "source"))), Me(r));
	return e.content.forEach((t, n) => {
		if (Ne(t)) {
			i.append(w("div", "moddoc", F(r, t.moddoc)));
			return;
		}
		let a = e.page.lines[n];
		i.append(Ae(r, t, a === 0 || a === void 0 ? null : a));
	}), i.querySelectorAll("a[data-cite]").forEach((e, t) => {
		e.removeAttribute("data-cite"), e.id = `_backref_${t}`;
	}), i;
}
function Ie(e, t, n, r) {
	let i = new Map(n.map((e) => [e.n, e]));
	for (let n of e.querySelectorAll(".modmeta .imports:not([data-fill]) li")) {
		let e = n.querySelector("a") ? void 0 : i.get(n.textContent ?? "");
		e && n.replaceChildren(T("", t.at(e.p), e.n));
	}
	let a = e.querySelector("[data-fill=\"imported-by\"]"), o = (i.get(r)?.i ?? []).map((e) => n[e]).filter((e) => e !== void 0).sort((e, t) => e.n.localeCompare(t.n));
	!a || o.length === 0 || (a.querySelector("ul")?.append(...o.map((e) => w("li", "", T("", t.at(e.p), e.n)))), a.querySelector("summary")?.append(w("span", "count", ` ${o.length}`)), a.hidden = !1);
}
//#endregion
//#region src/draw-plain.ts
var Le = "API documentation for every module of this package, generated from the compiled environment. Declarations link to their pinned source; an import of a dependency links to that dependency's source at the revision this package is built against.";
function z(e, t) {
	return w("div", "", w("dt", "", e), w("dd", "", t));
}
function Re(e, t) {
	let n = w("li", "", T("", e.at(t.p), ...D(t.n)));
	return t.s !== void 0 && n.append(w("span", "modsummary", O(t.s))), n;
}
function ze(e, t, n, r) {
	let i = n.modules, a = [w("div", "modhead", w("h1", "", t.title), w("p", "lede", Le))];
	if (r) {
		let t = {
			...e,
			roots: r.roots
		};
		a.push(w("div", "intro doc", be(r.html, r.words, t)));
	}
	let o = w("dl", "stats", z("Modules", pe(i.length)));
	return n.declarations !== void 0 && o.append(z("Declarations", pe(n.declarations))), t.lean && o.append(z("Lean", t.lean)), a.push(o, w("h2", "section-title", "Modules"), w("ul", i.some((e) => e.s !== void 0) ? "modlist modlist-described" : "modlist", ...i.map((t) => Re(e, t)))), a;
}
function Be(e, t, [n, r, i]) {
	let a = T("", M(e, n, `_backref_${r}`), `[${t}]`);
	return a.title = `File: ${n}${i ? `\nLocation: ${i}` : ""}`, [document.createTextNode(" "), a];
}
function Ve(e, t) {
	let n = t.map((t) => {
		let n = `ref_${t.key}`, r = E(w("li", "", T("", e.here(n), t.tag), " ", O(t.html)), n);
		return t.by.length > 0 && r.append(w("small", "", ...t.by.flatMap((t, n) => Be(e, n + 1, t)))), r;
	});
	return [w("div", "modhead", w("h1", "", "References")), w("div", "doc", w("ul", "", ...n))];
}
function He(e, t, n) {
	let r = E(w("h2", "section-title", "Did you mean"), "how-about-heading");
	return r.hidden = !0, [
		w("div", "modhead", w("h1", "", "Page not found"), w("p", "lede", "Nothing in this documentation is at ", w("code", "missing-path", t), `. If a declaration has moved, the closest matches in version ${n} are below; otherwise the `, T("", e.at("index.html"), "module index"), " lists every page.")),
		r,
		E(w("ul", "results"), "how-about")
	];
}
//#endregion
//#region src/frame.ts
var Ue = "<svg viewBox=\"0 0 20 20\" aria-hidden=\"true\"><path d=\"M3 5h14M3 10h14M3 15h14\"/></svg>", We = "<svg viewBox=\"0 0 20 20\" aria-hidden=\"true\"><path d=\"M10 3a7 7 0 1 0 7 7 5.5 5.5 0 0 1-7-7z\"/></svg>";
function Ge(e, t, n) {
	let r = E(w("button", "iconbtn", O(n)), e);
	return r.setAttribute("aria-label", t), r;
}
function Ke(e, t, n) {
	let r = w("header", "topbar");
	if (n) {
		let e = Ge("nav-toggle", "Modules", Ue);
		e.setAttribute("aria-expanded", "false"), e.setAttribute("aria-controls", "sidebar"), r.append(e);
	}
	let i = E(w("input", ""), "search-input");
	i.type = "search", i.name = "q", i.autocomplete = "off", i.spellcheck = !1, i.placeholder = "Search declarations", i.setAttribute("aria-label", "Search declarations");
	let a = E(w("ul", "search-results"), "search-results");
	a.hidden = !0;
	let o = w("form", "search", i, a);
	return o.setAttribute("role", "search"), o.setAttribute("action", e.at("search.html")), r.append(T("home", e.at("index.html"), t), o, Ge("theme-toggle", "Theme", We)), r;
}
var qe = (e) => T("skip", e.here("content"), "Skip to content");
function B(e, t, ...n) {
	let r = E(w("main", "content", ...n), "content");
	return [
		qe(e),
		Ke(e, t, !1),
		w("div", "shell", r)
	];
}
function Je(e, t, n, r) {
	let i = E(w("div", "scrim"), "scrim");
	i.hidden = !0;
	let a = E(w("nav", "sidebar"), "sidebar");
	if (a.setAttribute("aria-label", "Navigation"), n.length > 0) {
		let t = w("ul", "toc", ...n.map((t) => w("li", "", T("", e.here(t), ...D(t)))));
		a.append(w("section", "side", w("h2", "side-title", "On this page"), t));
	}
	return a.append(w("details", "side", w("summary", "side-title", "Modules"), E(w("div", "tree"), "module-tree"))), [
		qe(e),
		Ke(e, t, !0),
		w("div", "shell", i, a, E(r, "content"))
	];
}
//#endregion
//#region src/gzip.ts
var Ye = (e) => e.length >= 2 && e[0] === 31 && e[1] === 139;
async function Xe(e) {
	if (!Ye(e)) return e;
	let t = new Blob([e]).stream().pipeThrough(new DecompressionStream("gzip"));
	return new Uint8Array(await new Response(t).arrayBuffer());
}
//#endregion
//#region src/store-data.ts
var Ze = new TextDecoder(), Qe = /* @__PURE__ */ new Map(), $e = (e, t) => `d/${e}.${t}.gz`;
function et(e, t, n) {
	let r = new URL(e + $e(t, n), location.href).href, i = Qe.get(r);
	return i || (i = fetch(r).then((e) => e.ok ? e.arrayBuffer() : Promise.reject(/* @__PURE__ */ Error(`${e.status} ${r}`))).then((e) => Xe(new Uint8Array(e))), Qe.set(r, i)), i;
}
async function V(e, t) {
	return JSON.parse(Ze.decode(await et(e, t, "json")));
}
//#endregion
//#region src/route.ts
function tt(e, t) {
	let { root: n, version: i, data: a } = e;
	if (n === void 0 || i === void 0 || a === void 0) return null;
	let o = {
		root: n,
		version: i,
		data: a,
		mode: "path",
		query: t.search,
		anchor: t.hash.length > 1 ? r(t.hash.slice(1)) : null
	};
	return e.page === void 0 ? e.references === void 0 ? e.kind === "search" ? {
		...o,
		kind: "search"
	} : e.kind === "foundational" ? {
		...o,
		kind: "foundational"
	} : e.kind === "not-found" ? {
		...o,
		kind: "not-found",
		asked: e.asked ?? "",
		guess: e.guess ?? ""
	} : {
		...o,
		kind: "index"
	} : {
		...o,
		kind: "references",
		references: e.references
	} : {
		...o,
		kind: "module",
		module: e.module ?? "",
		page: e.page,
		usedBy: e.usedBy ?? ""
	};
}
function H(e) {
	return e.kind === "module" ? le(e.module) : e.kind === "references" ? "references.html" : e.kind === "search" ? "search.html" : e.kind === "foundational" ? j : "index.html";
}
var U = (e, t) => e.mode === "hash" ? a(e.version, t) : `${e.root}${e.version}/${t}`, W = (e, t) => H(e) + (e.kind === "search" ? e.query : "") + (t === null ? "" : `#${t}`), nt = (e, t) => e.kind === t.kind && e.mode === t.mode && e.version === t.version && W(e, null) === W(t, null) && (e.kind !== "not-found" || t.kind !== "not-found" || e.asked === t.asked), G = (e, t, n) => ({
	at: (t) => U(e, t),
	here: (t) => e.mode === "hash" ? U(e, W(e, t)) : `#${t}`,
	roots: n,
	bases: t.roots
}), K = (e, t) => t && t !== e ? `${e} · ${t}` : e;
async function rt(e) {
	let [t, n] = await Promise.all([V(e.root, e.data), V(e.root, e.page)]), r = n.content === null ? [] : await V(e.root, n.content), i = G(e, t, n.roots), a = Fe({
		linker: i,
		version: t,
		page: n,
		content: r
	});
	return a.querySelector(".modmeta .imports:not([data-fill])")?.addEventListener("toggle", () => {
		V(e.root, t.modules).then((e) => Ie(a, i, e.modules, n.module));
	}, { once: !0 }), {
		title: K(n.module, t.title),
		nodes: Je(i, t.title, Pe(r), a),
		plain: !1,
		version: t,
		linker: i
	};
}
async function it(e) {
	let t = await V(e.root, e.data), [n, r] = await Promise.all([V(e.root, t.modules), t.front === null ? null : V(e.root, t.front)]), i = G(e, t, []);
	return {
		title: t.title,
		nodes: B(i, t.title, ...ze(i, t, n, r)),
		plain: !0,
		version: t,
		linker: i
	};
}
async function at(e) {
	let [t, n] = await Promise.all([V(e.root, e.data), V(e.root, e.references)]), r = G(e, t, []);
	return {
		title: K("References", t.title),
		nodes: B(r, t.title, ...Ve(r, n)),
		plain: !0,
		version: t,
		linker: r
	};
}
async function q(e, t, n) {
	let r = await V(e.root, e.data), i = G(e, r, []);
	return {
		title: K(t, r.title),
		nodes: B(i, r.title, ...n(i)),
		plain: !0,
		version: r,
		linker: i
	};
}
function ot(e, t) {
	return e.kind === "module" ? rt(e) : e.kind === "references" ? at(e) : e.kind === "search" ? q(e, "Search", () => [...t]) : e.kind === "foundational" ? q(e, "Foundational types", () => [...t]) : e.kind === "not-found" ? q(e, "Not found", (t) => He(t, e.asked, e.version)) : it(e);
}
//#endregion
//#region src/search-box.ts
var st = 90, ct = 30;
function lt(e, t = new AbortController().signal) {
	let n = document.getElementById("search-input"), r = document.getElementById("search-results");
	if (!n || !r) return;
	let i = [], a = -1, o = 0, s = () => {
		r.hidden = !0, r.textContent = "", i = [], a = -1;
	}, c = async () => {
		let t = n.value.trim().toLowerCase();
		if (t.length < 2) return s();
		let o = await e.data();
		if (!o) return s();
		let c = S(o.index, t);
		if (r.textContent = "", c.length === 0) {
			let e = document.createElement("li");
			e.className = "search-empty", e.textContent = "No matching declaration", r.append(e), r.hidden = !1;
			return;
		}
		i = c.slice(0, ct).map((t) => {
			let n = x(o, t, e.href);
			return r.append(n), n;
		}), a = -1, r.hidden = !1;
	}, l = (e) => {
		if (i.length === 0) return;
		i[a]?.removeAttribute("aria-selected"), a = (a + e + i.length) % i.length;
		let t = i[a];
		t && (t.setAttribute("aria-selected", "true"), t.scrollIntoView({ block: "nearest" }));
	};
	n.addEventListener("input", () => {
		clearTimeout(o), o = setTimeout(() => void c(), st);
	}), n.addEventListener("focus", () => void e.data()), n.addEventListener("keydown", (e) => {
		e.key === "ArrowDown" ? (e.preventDefault(), l(1)) : e.key === "ArrowUp" ? (e.preventDefault(), l(-1)) : e.key === "Escape" ? (s(), n.blur()) : e.key === "Enter" && a >= 0 && (e.preventDefault(), i[a]?.querySelector("a")?.click());
	}), document.addEventListener("click", (e) => {
		e.target?.closest(".search") || s();
	}, { signal: t }), document.addEventListener("keydown", (e) => {
		let t = document.activeElement?.tagName;
		e.key === "/" && t !== "INPUT" && t !== "TEXTAREA" && (e.preventDefault(), n.focus(), n.select());
	}, { signal: t });
}
//#endregion
//#region src/search-page.ts
var ut = 90, J = 200;
function dt(e, t = location.search) {
	let n = document.getElementById("page-results"), r = document.getElementById("page-note"), i = document.getElementById("search-input");
	if (!n || !i) return;
	document.getElementById("search-results")?.remove();
	let a = new URLSearchParams(t).get("q");
	a && !i.value && (i.value = a);
	let o = async () => {
		let t = i.value.trim().toLowerCase();
		if (n.textContent = "", t.length < 2) {
			r && (r.textContent = "Type at least two characters.");
			return;
		}
		let a = await e.data();
		if (!a) {
			r && (r.textContent = "The search index could not be loaded.");
			return;
		}
		let o = S(a.index, t);
		for (let t of o.slice(0, J)) n.append(x(a, t, e.href));
		r && (r.textContent = o.length === 0 ? "No matching declaration." : o.length > J ? `${o.length} matches, showing the first ${J}.` : `${o.length} match${o.length === 1 ? "" : "es"}.`);
	}, s = 0;
	i.addEventListener("input", () => {
		clearTimeout(s), s = setTimeout(() => void o(), ut);
	}), i.form?.addEventListener("submit", (e) => {
		e.preventDefault(), o();
	}), i.focus(), o();
}
//#endregion
//#region src/instances.ts
function ft(e, t, n, r) {
	let i = document.createElement("li"), a = document.createElement("a");
	a.textContent = t;
	let o = e && n !== void 0 ? e.modules[y(e.index, n)] : void 0;
	return a.href = o ? r(`${o.p}#${t}`) : `#${t}`, i.append(a), i;
}
//#endregion
//#region src/tree.ts
function pt(e) {
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
function mt(e, t, n, r) {
	let i = document.createElement("ul");
	for (let [a, o] of e.children) {
		let e = t ? `${t}.${a}` : a, s = document.createElement("li"), c = document.createElement("div");
		c.className = "row";
		let l = null;
		if (o.children.size > 0) {
			l = mt(o, e, n, r), l.hidden = !(n === e || n.startsWith(`${e}.`));
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
//#endregion
//#region src/store-fill.ts
var ht = (e) => w("li", "search-empty", e);
async function gt(e, t, n) {
	let r = await V(e.root, e.usedBy).catch(() => null), i = r?.[t] ?? [];
	if (i.length === 0) {
		n.replaceChildren(ht(r ? "None" : "Index unavailable"));
		return;
	}
	n.replaceChildren(...i.map(([t, n]) => w("li", "", T("", M(e.linker, n, t), t))));
}
async function _t(e, t, n, r) {
	let [i, a] = await Promise.all([V(e.root, e.version.instances).catch(() => null), e.source.data()]), o = i?.[t]?.[n] ?? [];
	if (o.length === 0) {
		r.replaceChildren(ht(i ? "None" : "Index unavailable"));
		return;
	}
	let s = a ? b(a.index, o) : /* @__PURE__ */ new Map();
	r.replaceChildren(...o.map((t) => ft(a, t, s.get(t), e.source.href)));
}
function vt(e, t) {
	for (let n of e.querySelectorAll("details[data-fill]")) {
		let e = n.dataset.fill, r = n.dataset.name ?? "", i = n.querySelector("ul");
		!i || e === "imported-by" || n.addEventListener("toggle", () => {
			e === "used-by" ? gt(t, r, i) : _t(t, e === "instances" ? "instances" : "instancesFor", r, i);
		}, { once: !0 });
	}
}
function yt(e) {
	let t = document.getElementById("module-tree"), n = t?.closest("details");
	!t || !n || (n.addEventListener("toggle", () => {
		V(e.root, e.version.modules).then((n) => {
			t.replaceChildren(mt(pt(n.modules), "", e.module, e.linker.at)), t.querySelector("[aria-current]")?.scrollIntoView({ block: "center" });
		});
	}, { once: !0 }), document.getElementById("nav-toggle")?.addEventListener("click", () => {
		document.body.dataset.nav === "open" && (n.open = !0);
	}));
}
//#endregion
//#region src/store-search.ts
function bt(e, t, n) {
	let r = null, i = async () => {
		let [n, r] = await Promise.all([V(e, t.modules), et(e, t.search, "bin")]), i = h(r);
		return i ? {
			modules: n.modules,
			index: i
		} : null;
	};
	return {
		data: () => (r ??= i().catch(() => null), r),
		href: n
	};
}
//#endregion
//#region src/theme-key.ts
var xt = "litedoc4-theme", Y = [
	"auto",
	"light",
	"dark"
], St = (e) => e !== null && Y.includes(e);
function Ct() {
	try {
		let e = localStorage.getItem(xt);
		return St(e) ? e : "auto";
	} catch {
		return "auto";
	}
}
function wt(e) {
	e === "auto" ? delete document.documentElement.dataset.theme : document.documentElement.dataset.theme = e;
	let t = document.getElementById("theme-toggle");
	t && (t.title = `Theme: ${e}`, t.ariaLabel = t.title);
}
function Tt() {
	wt(Ct()), document.getElementById("theme-toggle")?.addEventListener("click", () => {
		let e = Y[(Y.indexOf(Ct()) + 1) % Y.length];
		try {
			localStorage.setItem(xt, e);
		} catch {}
		wt(e);
	});
}
//#endregion
//#region src/listed.ts
var Et = [
	"index.html",
	"references.html",
	"search.html",
	j
];
async function Dt(e, t) {
	return (await V(e, (await V(e, t.data)).modules)).modules;
}
var Ot = (e, t) => Et.includes(t) || e.some((e) => e.p === t);
//#endregion
//#region src/versions.ts
function kt(e, t, n) {
	let r = {
		...e,
		version: t
	};
	return e.kind === "module" ? n !== null && Ot(n, H(e)) ? U(r, W(e, e.anchor)) : U(r, `index.html?${C}=${encodeURIComponent(e.module)}`) : U(r, W(e, e.anchor));
}
function At(e) {
	if (e.mode === "hash") {
		let t = o(location.hash);
		return {
			...e,
			query: t?.query ?? "",
			anchor: t?.anchor ?? null
		};
	}
	let t = location.hash.slice(1);
	return {
		...e,
		query: location.search,
		anchor: t ? r(t) : null
	};
}
async function jt(e, t) {
	let n = At(e);
	return n.kind === "module" ? kt(n, t.name, await Dt(n.root, t)) : kt(n, t.name, null);
}
var Mt = /* @__PURE__ */ new Map();
function Nt(e) {
	let t = Mt.get(e);
	return t || (t = fetch(new URL(`${e}versions.json`, location.href)).then((e) => e.ok ? e.json() : null).catch(() => null), Mt.set(e, t)), t;
}
function X(...e) {
	let t = w("p", "results-note", ...e);
	return t.setAttribute("role", "status"), document.getElementById("content")?.prepend(t), t;
}
var Pt = (e, t) => history.replaceState(history.state, "", U(e, t));
function Ft(e) {
	let t = new URLSearchParams(e.query).get(C);
	e.kind === "index" && t !== null && (X(`The module ${t} does not exist in version ${e.version}.`), Pt(e, W(e, e.anchor))), e.kind === "module" && e.anchor !== null && document.getElementById(e.anchor) === null && (X(`The declaration ${e.anchor} does not exist in version ${e.version} of ${e.module}.`), Pt(e, W(e, null)));
}
async function It(e, t, n) {
	try {
		location.assign(new URL(await jt(e, t), location.href).href);
	} catch {
		n.value = e.version;
	}
}
async function Lt(e, t) {
	if (document.querySelector("link[rel=\"canonical\"]")?.remove(), e.mode === "hash" || e.kind === "not-found") return;
	if (e.kind === "module" && e.version !== t.name) {
		let n = await Dt(e.root, t).catch(() => null);
		if (n === null || !Ot(n, H(e))) return;
	}
	let n = document.createElement("link");
	n.rel = "canonical", n.href = new URL(U({
		...e,
		version: t.name
	}, H(e)), location.href).href, document.head.append(n);
}
async function Rt(e) {
	let t = await Nt(e.root);
	if (!t || t.length === 0) return;
	let n = w("select", "versions");
	n.setAttribute("aria-label", "Version");
	for (let r of [...t].reverse()) {
		let t = w("option", "", r.name);
		t.value = r.name, t.selected = r.name === e.version, n.append(t);
	}
	n.addEventListener("change", () => {
		let r = t.find((e) => e.name === n.value);
		r && It(e, r, n);
	}), document.querySelector(".topbar .home")?.after(n);
	let r = t[t.length - 1];
	if (r) {
		if (r.name !== e.version) {
			let t = w("button", "", `Go to ${r.name}`);
			t.type = "button", t.addEventListener("click", () => void It(e, r, n)), X(`This is version ${e.version}; the newest is ${r.name}. `, t);
		}
		Lt(e, r);
	}
}
//#endregion
//#region src/store-page.ts
var Z = document.body;
function Q(e) {
	let t = document.createElement("p");
	t.className = "lede", t.textContent = `This page's data could not be loaded (${e instanceof Error ? e.message : String(e)}).`, Z.replaceChildren(t), Z.dataset.drawn = "failed";
}
function $(e) {
	for (let e of document.querySelectorAll(".targeted")) e.classList.remove("targeted");
	let t = e.anchor === null ? null : document.getElementById(e.anchor);
	if (!t) {
		scrollTo(0, 0);
		return;
	}
	t.classList.add("targeted"), t.scrollIntoView();
}
function zt(e) {
	e.mode === "hash" ? $(e) : location.hash && location.replace(location.href);
}
function Bt(e, t) {
	let n = document.getElementById("search-input");
	n?.form?.addEventListener("submit", (t) => {
		t.preventDefault(), location.hash = U(e, `search.html?q=${encodeURIComponent(n.value)}`);
	}, { signal: t });
}
async function Vt(e, n, r) {
	delete Z.dataset.drawn;
	let i;
	try {
		i = await ot(e, n);
	} catch (e) {
		Q(e);
		return;
	}
	if (r.aborted) return;
	document.title = i.title, Z.classList.toggle("plain", i.plain), Z.replaceChildren(...i.nodes), Tt(), t(r);
	let a = bt(e.root, i.version, i.linker.at);
	if (e.kind === "search" ? dt(a, e.query) : e.mode === "hash" && Bt(e, r), lt(a, r), e.kind === "module") {
		let t = {
			...e,
			version: i.version,
			linker: i.linker,
			source: a
		};
		vt(Z, t), yt(t);
	}
	e.kind === "not-found" && ae(a, e.guess), Ft(e), Z.dataset.drawn = "1", zt(e), Rt(e).then(() => {
		!r.aborted && e.mode === "hash" && e.anchor !== null && $(e);
	});
}
var Ht = (e) => {
	let t = document.querySelector(e);
	return t ? [...t.content.childNodes] : [];
};
async function Ut(e, t) {
	let n = t[t.length - 1], i = o(location.hash);
	if (i === null) return history.replaceState(history.state, "", a(n.name, "index.html")), {
		root: e,
		version: n.name,
		data: n.data,
		mode: "hash",
		query: "",
		anchor: null,
		kind: "index"
	};
	let s = t.find((e) => e.name === i.version);
	if (!s) {
		let t = r(location.hash);
		return {
			root: e,
			version: n.name,
			data: n.data,
			mode: "hash",
			query: "",
			anchor: null,
			kind: "not-found",
			asked: t,
			guess: i.anchor ?? i.page.split("/").join(".")
		};
	}
	let c = {
		root: e,
		version: s.name,
		data: s.data,
		mode: "hash",
		query: i.query,
		anchor: i.anchor
	};
	if (V(e, s.data).catch(() => null), i.page === "") return {
		...c,
		kind: "index"
	};
	if (i.page === "search") return {
		...c,
		kind: "search"
	};
	if (i.page === "foundational_types") return {
		...c,
		kind: "foundational"
	};
	if (i.page === "references") {
		let t = await V(e, s.data);
		return {
			...c,
			kind: "references",
			references: t.references
		};
	}
	let l = s.routes === void 0 ? {} : await V(e, s.routes), u = Object.hasOwn(l, i.page) ? l[i.page] : void 0;
	if (!u) {
		let e = i.page.split("/").join(".");
		return {
			...c,
			kind: "index",
			query: `?${C}=${encodeURIComponent(e)}`,
			anchor: null
		};
	}
	let [d, f] = u, p = await V(e, d);
	return {
		...c,
		kind: "module",
		module: p.module,
		page: d,
		usedBy: f
	};
}
async function Wt(e) {
	let t = {
		search: Ht("template#search-body"),
		foundational: Ht("template#foundational-body")
	}, n = await Nt(e);
	if (!n || n.length === 0) {
		Q(/* @__PURE__ */ Error("versions.json"));
		return;
	}
	let r = null, i = null, a = async () => {
		let a;
		try {
			a = await Ut(e, n);
		} catch (e) {
			Q(e);
			return;
		}
		if (r !== null && nt(r, a)) {
			r = a, $(a);
			return;
		}
		i?.abort(), i = new AbortController(), r = a;
		let o = a.kind === "search" ? t.search : a.kind === "foundational" ? t.foundational : [];
		await Vt(a, o.map((e) => e.cloneNode(!0)), i.signal);
	};
	addEventListener("hashchange", () => void a()), await a();
}
function Gt() {
	if (Z.dataset.mode === "hash") {
		Wt(Z.dataset.root ?? "./");
		return;
	}
	let e = tt(Z.dataset, location);
	e && Vt(e, [...Z.childNodes], new AbortController().signal);
}
Gt();
//#endregion
