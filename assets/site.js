//#region src/site.ts
var e = document.body;
e.dataset.root, e.dataset.module;
//#endregion
//#region src/drawer.ts
function t() {
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
//#region src/dom.ts
function n(e, t, ...n) {
	let r = document.createElement(e);
	return t && (r.className = t), r.append(...n), r;
}
function r(e, t, ...r) {
	let i = n("a", e, ...r);
	return i.setAttribute("href", t), i;
}
function i(e, t) {
	return e.id = t, e;
}
function a(e) {
	let t = [];
	return e.split(".").forEach((e, r) => {
		r > 0 && t.push(document.createTextNode(".")), t.push(n("span", "name", e));
	}), t;
}
function o(e) {
	let t = document.createElement("template");
	return t.innerHTML = e, t.content;
}
//#endregion
//#region src/names.ts
var s = (e) => e.length >= 2 && e.startsWith("«") && e.endsWith("»") ? e.slice(1, -1) : e;
function c(e) {
	let t = [], n = 0, r = 0;
	for (let i = 0; i < e.length; i++) {
		let a = e[i];
		a === "«" ? n++ : a === "»" ? n-- : a === "." && n === 0 && (t.push(s(e.slice(r, i))), r = i + 1);
	}
	return t.push(s(e.slice(r))), t;
}
var l = (e) => c(e).join("/"), u = (e) => `${l(e)}.html`, d = (e, t) => `${e}/${l(t)}.lean`, f = (e, t, n) => d(e, t) + (n ? `#L${n[0]}-L${n[1]}` : ""), p = (e) => e.slice(e.lastIndexOf(".") + 1);
function m(e, t) {
	let n = (e) => t.includes(e);
	if (e === "definition" || e === "instance") {
		let t = n("unsafe") ? "unsafe " : "", r = n("noncomputable") ? "noncomputable " : "", i = e === "instance" ? "instance" : n("abbrev") ? "abbrev" : "def";
		return t + r + i;
	}
	return e === "axiom" && n("unsafe") ? "unsafe axiom" : e === "opaque" && n("partial") ? "partial def" : e === "opaque" && n("unsafe") ? "unsafe opaque" : e === "inductive" && n("unsafe") ? "unsafe inductive" : e === "class_inductive" ? "class inductive" : e;
}
function h(e) {
	return e === "definition" ? "def" : e === "class_inductive" ? "class" : e === "constructor" ? "ctor" : e;
}
var g = (e) => String(e).replace(/\B(?=(\d{3})+$)/g, ","), _ = "foundational_types.html", v = (e, t, n) => e.at(u(t) + (n === null ? "" : `#${n}`)), ee = (e) => typeof e[0] == "number";
function te(e, t, n) {
	if (ee(n)) {
		let t = e.bases[e.roots[n[0]] ?? ""];
		return t === void 0 ? null : f(t, n[1], n.length === 4 ? [n[2], n[3]] : null);
	}
	let r = n;
	return v(e, r[0], r.length === 1 ? t : r[1]);
}
function y(e, t, n) {
	if (!Object.hasOwn(t, n)) return null;
	let r = t[n];
	return r === void 0 ? null : te(e, n, r);
}
//#endregion
//#region src/spans.ts
var ne = (e) => typeof e == "string" ? [e, []] : e;
function re(e, t, n) {
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
function ie(e, t) {
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
function ae(e, t, n) {
	if (e.startsWith("##")) {
		let r = e.slice(2);
		return n(r) ?? t(`search.html?q=${encodeURIComponent(r)}`);
	}
	return e.startsWith("#") || e.startsWith("http") ? e : t(e);
}
function b(e, t, n) {
	let i = (e) => y(n, t, e), a = o(e);
	for (let e of a.querySelectorAll("a[href]")) e.setAttribute("href", ae(e.getAttribute("href") ?? "", n.at, i));
	for (let e of [...a.querySelectorAll("w")]) {
		let t = ie(e.textContent ?? "", i), n = [];
		t.before && n.push(document.createTextNode(t.before)), t.href !== null && n.push(r("", t.href, t.linked)), e.replaceWith(...n);
	}
	return a;
}
//#endregion
//#region src/draw-module.ts
function x(e, t) {
	let [n, i] = ne(t);
	return re(n, i, (t) => t.length === 2 ? e.l.at(_) : y(e.l, e.page.names, t[2])).map((e) => e.href === null ? document.createTextNode(e.text) : r("", e.href, e.text));
}
var S = (e, t) => b(t, e.page.words, e.l);
function C(e, t) {
	return (t ?? []).flatMap(([t, r]) => [n("span", t ? "binder implicit" : "binder", n("span", "fn", ...x(e, r))), document.createTextNode("\n")]);
}
function oe(e, t) {
	let r = n("div", "sig", ...C(e, t.b));
	return (t.k === "structure" || t.k === "class") && t.p && t.p.length > 0 && (r.append(n("span", "extends", "extends"), " "), t.p.forEach(([t, a], o) => {
		o > 0 && r.append(", "), r.append(i(n("span", "", ...x(e, a)), t));
	})), r.append(n("span", "colon", " :"), n("div", "sig-type", ...x(e, t.t))), r;
}
function se(e, t, i) {
	let o = i ? `#L${i[0]}-L${i[1]}` : "";
	return n("header", "decl-head", n("span", "kind", m(t.k, t.mods ?? [])), n("h2", "decl-name", r("break_within", v(e.l, e.page.module, t.n), ...a(t.n))), r("src", e.sourceUrl + o, "source"));
}
function w(e, ...t) {
	let r = n("span", "flag", ...t);
	return r.dataset.flag = e, r;
}
function ce(e, t) {
	let i = [];
	if (t.sorry === "direct" && i.push(w("sorry-direct", "uses ", n("code", "", "sorry"))), t.sorry === "transitive" && i.push(w("sorry-transitive", "depends on ", n("code", "", "sorry"))), t.gen) {
		let [a, o] = t.gen, s = y(e.l, e.page.names, o), c = n("code", "", o);
		i.push(w("generated", "realized by ", n("code", "", `@[${a}]`), " from ", s === null ? c : r("", s, c)));
	}
	return i.length === 0 ? null : n("div", "flags", ...i);
}
function T(e, t, r) {
	let i = n("details", "extra", n("summary", "", r), n("ul", ""));
	return i.dataset.fill = e, i.dataset.name = t, i;
}
function le(e, t) {
	if (!t.eq && !t.eqOmitted) return null;
	let r = n("ul", "equations");
	t.eqOmitted && r.append(n("li", "", "One or more equations did not get rendered due to their size."));
	for (let i of t.eq ?? []) r.append(n("li", "", ...x(e, i)));
	return n("details", "extra", n("summary", "", "Equations"), r);
}
function E(e, t, r) {
	return n("div", "field-sig", t, ...C(e, r.b), n("span", "colon", " : "), ...x(e, r.t));
}
function ue(e, t, r) {
	return r.doc && t.append(n("div", "field-doc", S(e, r.doc))), t;
}
function de(e, t, a) {
	let o = p(a.n);
	if (!a.inh) return ue(e, i(n("li", "field", E(e, n("span", "field-name", o), a)), a.n), a);
	let s = y(e.l, e.page.names, a.n), c = n("li", "field inherited", E(e, s === null ? n("span", "field-name", o) : r("field-name", s, o), a));
	return a.id && (c.id = `${t.n}.${o}`), c;
}
function fe(e, t) {
	let r = t.ctor ?? `${t.n}.mk`, a = p(r), o = [];
	return a !== "mk" && o.push(n("p", "ctor-note", "constructor ", n("code", "", a))), o.push(i(n("ul", "fields", ...(t.f ?? []).map((n) => de(e, t, n))), r)), o;
}
function D(e, t) {
	let r = t.c ?? [];
	return r.length === 0 ? [] : [n("ul", "ctors", ...r.map((t) => ue(e, i(n("li", "ctor", E(e, n("span", "field-name", p(t.n)), t)), t.n), t)))];
}
function pe(e, t, r) {
	let a = i(n("section", "decl"), t.n);
	a.dataset.kind = h(t.k), a.append(se(e, t, r));
	let o = ce(e, t);
	o && a.append(o), t.attrs && t.attrs.length > 0 && a.append(n("div", "attrs", `@[${t.attrs.join(", ")}]`)), a.append(oe(e, t)), t.doc && a.append(n("div", "doc", S(e, t.doc)));
	let s = [], c = () => {
		let n = le(e, t);
		n && s.push(n);
	};
	return t.k === "structure" || t.k === "class" ? (a.append(...fe(e, t)), s.push(t.k === "class" ? T("instances", t.n, "Instances") : T("instances-for", t.n, "Instances For"))) : t.k === "definition" ? (c(), s.push(T("instances-for", t.n, "Instances For"))) : t.k === "instance" ? c() : t.k === "inductive" ? (a.append(...D(e, t)), s.push(T("instances-for", t.n, "Instances For"))) : t.k === "class_inductive" && (a.append(...D(e, t)), s.push(T("instances", t.n, "Instances"))), s.push(T("used-by", t.n, "Used by")), a.append(...s), a;
}
function me(e, t) {
	let i = e.l.bases[c(t)[0] ?? ""];
	return n("li", "", i === void 0 ? t : r("", d(i, t), t));
}
function he(e) {
	let t = e.page.imports, r = n("summary", "", "Imports");
	t.length > 0 && r.append(" ", n("span", "count", String(t.length)));
	let i = n("details", "imports", r, n("ul", "", ...t.map((t) => me(e, t)))), a = n("details", "imports", n("summary", "", "Imported by"), n("ul", ""));
	return a.dataset.fill = "imported-by", a.hidden = !0, n("div", "modmeta", i, a);
}
var O = (e) => "moddoc" in e;
function ge(e) {
	return e.flatMap((e) => O(e) ? [] : [e.n]);
}
function _e(e) {
	let t = e.page.module, i = d(e.version.source, t), o = {
		l: e.linker,
		page: e.page,
		sourceUrl: i
	}, s = n("main", "content", n("div", "modhead", n("h1", "", ...a(t)), n("p", "modactions", r("src", i, "source"))), he(o));
	return e.content.forEach((t, r) => {
		if (O(t)) {
			s.append(n("div", "moddoc", S(o, t.moddoc)));
			return;
		}
		let i = e.page.lines[r];
		s.append(pe(o, t, i === 0 || i === void 0 ? null : i));
	}), s.querySelectorAll("a[data-cite]").forEach((e, t) => {
		e.removeAttribute("data-cite"), e.id = `_backref_${t}`;
	}), s;
}
function ve(e, t, i, a) {
	let o = new Map(i.map((e) => [e.n, e]));
	for (let n of e.querySelectorAll(".modmeta .imports:not([data-fill]) li")) {
		let e = n.querySelector("a") ? void 0 : o.get(n.textContent ?? "");
		e && n.replaceChildren(r("", t.at(e.p), e.n));
	}
	let s = e.querySelector("[data-fill=\"imported-by\"]"), c = (o.get(a)?.i ?? []).map((e) => i[e]).filter((e) => e !== void 0).sort((e, t) => e.n.localeCompare(t.n));
	!s || c.length === 0 || (s.querySelector("ul")?.append(...c.map((e) => n("li", "", r("", t.at(e.p), e.n)))), s.querySelector("summary")?.append(n("span", "count", ` ${c.length}`)), s.hidden = !1);
}
//#endregion
//#region src/draw-plain.ts
var ye = "API documentation for every module of this package, generated from the compiled environment. Declarations link to their pinned source; an import of a dependency links to that dependency's source at the revision this package is built against.";
function k(e, t) {
	return n("div", "", n("dt", "", e), n("dd", "", t));
}
function be(e, t) {
	let i = n("li", "", r("", e.at(t.p), ...a(t.n)));
	return t.s !== void 0 && i.append(n("span", "modsummary", o(t.s))), i;
}
function xe(e, t, r, i) {
	let a = r.modules, o = [n("div", "modhead", n("h1", "", t.title), n("p", "lede", ye))];
	if (i) {
		let t = {
			...e,
			roots: i.roots
		};
		o.push(n("div", "intro doc", b(i.html, i.words, t)));
	}
	let s = n("dl", "stats", k("Modules", g(a.length)));
	return r.declarations !== void 0 && s.append(k("Declarations", g(r.declarations))), t.lean && s.append(k("Lean", t.lean)), o.push(s, n("h2", "section-title", "Modules"), n("ul", a.some((e) => e.s !== void 0) ? "modlist modlist-described" : "modlist", ...a.map((t) => be(e, t)))), o;
}
function Se(e, t, [n, i, a]) {
	let o = r("", v(e, n, `_backref_${i}`), `[${t}]`);
	return o.title = `File: ${n}${a ? `\nLocation: ${a}` : ""}`, [document.createTextNode(" "), o];
}
function Ce(e, t) {
	let a = t.map((t) => {
		let a = `ref_${t.key}`, s = i(n("li", "", r("", `#${a}`, t.tag), " ", o(t.html)), a);
		return t.by.length > 0 && s.append(n("small", "", ...t.by.flatMap((t, n) => Se(e, n + 1, t)))), s;
	});
	return [n("div", "modhead", n("h1", "", "References")), n("div", "doc", n("ul", "", ...a))];
}
//#endregion
//#region src/frame.ts
var we = "<svg viewBox=\"0 0 20 20\" aria-hidden=\"true\"><path d=\"M3 5h14M3 10h14M3 15h14\"/></svg>", Te = "<svg viewBox=\"0 0 20 20\" aria-hidden=\"true\"><path d=\"M10 3a7 7 0 1 0 7 7 5.5 5.5 0 0 1-7-7z\"/></svg>";
function A(e, t, r) {
	let a = i(n("button", "iconbtn", o(r)), e);
	return a.setAttribute("aria-label", t), a;
}
function j(e, t) {
	let a = n("header", "topbar");
	if (t) {
		let e = A("nav-toggle", "Modules", we);
		e.setAttribute("aria-expanded", "false"), e.setAttribute("aria-controls", "sidebar"), a.append(e);
	}
	let o = i(n("input", ""), "search-input");
	o.type = "search", o.name = "q", o.autocomplete = "off", o.spellcheck = !1, o.placeholder = "Search declarations", o.setAttribute("aria-label", "Search declarations");
	let s = i(n("ul", "search-results"), "search-results");
	s.hidden = !0;
	let c = n("form", "search", o, s);
	return c.setAttribute("role", "search"), c.setAttribute("action", e.at("search.html")), a.append(r("home", e.at("index.html"), e.title), c, A("theme-toggle", "Theme", Te)), a;
}
var M = () => r("skip", "#content", "Skip to content");
function N(e, ...t) {
	let r = i(n("main", "content", ...t), "content");
	return [
		M(),
		j(e, !1),
		n("div", "shell", r)
	];
}
function Ee(e, t, o) {
	let s = i(n("div", "scrim"), "scrim");
	s.hidden = !0;
	let c = i(n("nav", "sidebar"), "sidebar");
	if (c.setAttribute("aria-label", "Navigation"), t.length > 0) {
		let e = n("ul", "toc", ...t.map((e) => n("li", "", r("", `#${e}`, ...a(e)))));
		c.append(n("section", "side", n("h2", "side-title", "On this page"), e));
	}
	return c.append(n("details", "side", n("summary", "side-title", "Modules"), i(n("div", "tree"), "module-tree"))), [
		M(),
		j(e, !0),
		n("div", "shell", s, c, i(o, "content"))
	];
}
//#endregion
//#region src/gzip.ts
var De = (e) => e.length >= 2 && e[0] === 31 && e[1] === 139;
async function Oe(e) {
	if (!De(e)) return e;
	let t = new Blob([e]).stream().pipeThrough(new DecompressionStream("gzip"));
	return new Uint8Array(await new Response(t).arrayBuffer());
}
//#endregion
//#region src/store-data.ts
var ke = new TextDecoder(), P = /* @__PURE__ */ new Map(), Ae = (e, t) => `d/${e}.${t}.gz`;
function F(e, t, n) {
	let r = new URL(e + Ae(t, n), location.href).href, i = P.get(r);
	return i || (i = fetch(r).then((e) => e.ok ? e.arrayBuffer() : Promise.reject(/* @__PURE__ */ Error(`${e.status} ${r}`))).then((e) => Oe(new Uint8Array(e))), P.set(r, i)), i;
}
async function I(e, t) {
	return JSON.parse(ke.decode(await F(e, t, "json")));
}
//#endregion
//#region src/route.ts
function je(e) {
	let { root: t, version: n, data: r } = e;
	if (t === void 0 || n === void 0 || r === void 0) return null;
	let i = {
		root: t,
		version: n,
		data: r
	};
	return e.page === void 0 ? e.references === void 0 ? e.kind === "search" ? {
		...i,
		kind: "search"
	} : e.kind === "foundational" ? {
		...i,
		kind: "foundational"
	} : {
		...i,
		kind: "index"
	} : {
		...i,
		kind: "references",
		references: e.references
	} : {
		...i,
		kind: "module",
		module: e.module ?? "",
		page: e.page,
		usedBy: e.usedBy ?? ""
	};
}
var Me = (e) => `${e.root}${e.version}/`;
function Ne(e) {
	return e.kind === "module" ? u(e.module) : e.kind === "references" ? "references.html" : e.kind === "search" ? "search.html" : e.kind === "foundational" ? _ : "index.html";
}
var L = (e, t, n) => {
	let r = Me(e);
	return {
		at: (e) => r + e,
		roots: n,
		bases: t.roots
	};
}, R = (e, t) => t && t !== e ? `${e} · ${t}` : e;
async function Pe(e) {
	let [t, n] = await Promise.all([I(e.root, e.data), I(e.root, e.page)]), r = n.content === null ? [] : await I(e.root, n.content), i = L(e, t, n.roots), a = _e({
		linker: i,
		version: t,
		page: n,
		content: r
	});
	return a.querySelector(".modmeta .imports:not([data-fill])")?.addEventListener("toggle", () => {
		I(e.root, t.modules).then((e) => ve(a, i, e.modules, n.module));
	}, { once: !0 }), {
		title: R(n.module, t.title),
		nodes: Ee({
			title: t.title,
			at: i.at
		}, ge(r), a),
		plain: !1,
		version: t,
		linker: i
	};
}
async function Fe(e) {
	let t = await I(e.root, e.data), [n, r] = await Promise.all([I(e.root, t.modules), t.front === null ? null : I(e.root, t.front)]), i = L(e, t, []);
	return {
		title: t.title,
		nodes: N({
			title: t.title,
			at: i.at
		}, ...xe(i, t, n, r)),
		plain: !0,
		version: t,
		linker: i
	};
}
async function Ie(e) {
	let [t, n] = await Promise.all([I(e.root, e.data), I(e.root, e.references)]), r = L(e, t, []);
	return {
		title: R("References", t.title),
		nodes: N({
			title: t.title,
			at: r.at
		}, ...Ce(r, n)),
		plain: !0,
		version: t,
		linker: r
	};
}
async function Le(e, t, n) {
	let r = await I(e.root, e.data), i = L(e, r, []);
	return {
		title: R(t, r.title),
		nodes: N({
			title: r.title,
			at: i.at
		}, ...n),
		plain: !0,
		version: r,
		linker: i
	};
}
function Re(e, t, n) {
	return e.kind === "module" ? Pe(e) : e.kind === "references" ? Ie(e) : e.kind === "search" || e.kind === "foundational" ? Le(e, t, n) : Fe(e);
}
//#endregion
//#region src/scratch.ts
var z = /* @__PURE__ */ new Uint8Array(512), B = /* @__PURE__ */ new Uint8Array(512);
function V(e) {
	if (e <= z.length) return;
	let t = z.length;
	for (; t < e;) t *= 2;
	let n = new Uint8Array(t);
	n.set(z);
	let r = new Uint8Array(t);
	r.set(B), z = n, B = r;
}
//#endregion
//#region src/index-format.ts
var ze = 1395934284, Be = 2, Ve = 52, H = new TextDecoder(), He = new TextEncoder(), U = /* @__PURE__ */ new Uint8Array(256);
for (let e = 0; e < 256; e++) U[e] = e >= 65 && e <= 90 ? e + 32 : e;
function Ue(e) {
	let t = (t) => (e[t] | e[t + 1] << 8 | e[t + 2] << 16) + e[t + 3] * 16777216, n = (t) => e[t] | e[t + 1] << 8;
	if (e.length < Ve || t(0) !== ze || t(4) !== Be) return null;
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
		i.labels.push(H.decode(e.subarray(o + 1, o + 1 + t))), o += 1 + t;
	}
	let s = t(44);
	o = s + 4;
	for (let r = 0, a = t(s); r < a; r++) {
		let r = n(o + 4);
		i.folds.set(t(o), e.subarray(o + 6, o + 6 + r)), o += 6 + r;
	}
	return i;
}
function W(e, t, n) {
	let r = 0;
	for (let i = t; i < n; i++) {
		let t = e[i];
		(t & 192) != 128 && (r += t >= 240 ? 2 : 1);
	}
	return r;
}
function We(e, t) {
	let n = e.bytes, r = Math.floor(t / e.restart), i = e.restarts + r * 4, a = e.names + ((n[i] | n[i + 1] << 8 | n[i + 2] << 16) + n[i + 3] * 16777216), o = /* @__PURE__ */ new Uint8Array(256), s = 0;
	for (let i = r * e.restart; i <= t; i++) {
		let e = n[a++], t = n[a++];
		if (t === 255 && (t = n[a] | n[a + 1] << 8, a += 2), e + t > o.length) {
			let n = new Uint8Array(Math.max(e + t, o.length * 2));
			n.set(o), o = n;
		}
		o.set(n.subarray(a, a + t), e), a += t, s = e + t;
	}
	return H.decode(o.subarray(0, s));
}
var Ge = (e, t) => e.labels[e.bytes[e.kindOf + t]] ?? "", G = (e, t) => e.bytes[e.moduleOf + t * 2] | e.bytes[e.moduleOf + t * 2 + 1] << 8;
function Ke(e, t) {
	let n = new Set(t), r = /* @__PURE__ */ new Map(), i = e.bytes, a = e.names;
	for (let t = 0; t < e.count && r.size < n.size; t++) {
		let e = i[a++], o = i[a++];
		o === 255 && (o = i[a] | i[a + 1] << 8, a += 2), V(e + o), z.set(i.subarray(a, a + o), e), a += o;
		let s = H.decode(z.subarray(0, e + o));
		n.has(s) && r.set(s, t);
	}
	return r;
}
//#endregion
//#region src/result-item.ts
function K(e, t, n) {
	let r = document.createElement("li"), i = document.createElement("a"), a = We(e.index, t), o = e.modules[G(e.index, t)];
	i.href = o ? `${n(o.p)}#${a}` : `#${a}`;
	let s = document.createElement("span");
	s.className = "kind", s.textContent = Ge(e.index, t);
	let c = document.createElement("span");
	c.textContent = a;
	let l = document.createElement("span");
	return l.className = "where", l.textContent = o?.n ?? "", i.append(s, c, l), r.append(i), r;
}
//#endregion
//#region src/score.ts
function q(e, t, n, r, i) {
	if (t - n >= i) {
		let a = !0;
		for (let t = 0; t < i; t++) if (e[n + t] !== r[t]) {
			a = !1;
			break;
		}
		if (a) return 3e3 - W(e, n, t);
	}
	if (t < i) return -1;
	let a = !0;
	for (let t = 0; t < i; t++) if (e[t] !== r[t]) {
		a = !1;
		break;
	}
	if (a) return 2e3 - W(e, 0, t);
	for (let n = 1; n <= t - i; n++) {
		let t = !0;
		for (let a = 0; a < i; a++) if (e[n + a] !== r[a]) {
			t = !1;
			break;
		}
		if (t) return 1e3 - W(e, 0, n);
	}
	return -1;
}
function J(e, t) {
	let n = Array.from({ length: t }, (e, t) => t);
	return n.sort((t, n) => e.score[n] - e.score[t] || e.length[t] - e.length[n] || e.id[t] - e.id[n]), n.map((t) => e.id[t]);
}
//#endregion
//#region src/search.ts
function qe(e, t) {
	let n = He.encode(t), r = n.length, i = e.narrow;
	if (i && t.startsWith(i.query)) return Je(e, i, n, r, t);
	let a = e.bytes, o = e.folds.size > 0, s = {
		names: [],
		starts: [],
		ids: []
	}, c = e.names, l = 0, u = -1;
	for (let t = 0; t < e.count; t++) {
		let i = a[c++], d = a[c++];
		d === 255 && (d = a[c] | a[c + 1] << 8, c += 2), V(i + d);
		for (let e = 0; e < d; e++) {
			let t = a[c + e];
			z[i + e] = t, B[i + e] = U[t];
		}
		c += d;
		let f = i + d, p = -1;
		for (let e = f - 1; e >= i; e--) if (B[e] === 46) {
			p = e;
			break;
		}
		if (p < 0) {
			if (u < i) p = u;
			else for (let e = i - 1; e >= 0; e--) if (B[e] === 46) {
				p = e;
				break;
			}
		}
		u = p;
		let m = B, h = f, g = p + 1;
		if (o) {
			let n = e.folds.get(t);
			if (n) {
				m = n, h = n.length, g = 0;
				for (let e = h - 1; e >= 0; e--) if (m[e] === 46) {
					g = e + 1;
					break;
				}
			}
		}
		let _ = q(m, h, g, n, r);
		_ > 0 && (e.id[l] = t, e.score[l] = _, e.length[l] = W(m, 0, h), l < 512 && (s.names.push(m.slice(0, h)), s.starts.push(g), s.ids.push(t)), l++);
	}
	return e.narrow = l <= 512 ? {
		query: t,
		...s
	} : null, J(e, l);
}
function Je(e, t, n, r, i) {
	let a = {
		names: [],
		starts: [],
		ids: []
	}, o = 0;
	for (let i = 0; i < t.ids.length; i++) {
		let s = t.names[i], c = q(s, s.length, t.starts[i], n, r);
		c > 0 && (e.id[o] = t.ids[i], e.score[o] = c, e.length[o] = W(s, 0, s.length), a.names.push(s), a.starts.push(t.starts[i]), a.ids.push(t.ids[i]), o++);
	}
	return e.narrow = {
		query: i,
		...a
	}, J(e, o);
}
//#endregion
//#region src/search-box.ts
var Ye = 90, Xe = 30;
function Ze(e) {
	let t = document.getElementById("search-input"), n = document.getElementById("search-results");
	if (!t || !n) return;
	let r = [], i = -1, a = 0, o = () => {
		n.hidden = !0, n.textContent = "", r = [], i = -1;
	}, s = async () => {
		let a = t.value.trim().toLowerCase();
		if (a.length < 2) return o();
		let s = await e.data();
		if (!s) return o();
		let c = qe(s.index, a);
		if (n.textContent = "", c.length === 0) {
			let e = document.createElement("li");
			e.className = "search-empty", e.textContent = "No matching declaration", n.append(e), n.hidden = !1;
			return;
		}
		r = c.slice(0, Xe).map((t) => {
			let r = K(s, t, e.href);
			return n.append(r), r;
		}), i = -1, n.hidden = !1;
	}, c = (e) => {
		if (r.length === 0) return;
		r[i]?.removeAttribute("aria-selected"), i = (i + e + r.length) % r.length;
		let t = r[i];
		t && (t.setAttribute("aria-selected", "true"), t.scrollIntoView({ block: "nearest" }));
	};
	t.addEventListener("input", () => {
		clearTimeout(a), a = setTimeout(() => void s(), Ye);
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
var Qe = 90, Y = 200;
function $e(e) {
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
		let o = qe(a.index, i);
		for (let n of o.slice(0, Y)) t.append(K(a, n, e.href));
		n && (n.textContent = o.length === 0 ? "No matching declaration." : o.length > Y ? `${o.length} matches, showing the first ${Y}.` : `${o.length} match${o.length === 1 ? "" : "es"}.`);
	}, o = 0;
	r.addEventListener("input", () => {
		clearTimeout(o), o = setTimeout(() => void a(), Qe);
	}), r.form?.addEventListener("submit", (e) => {
		e.preventDefault(), a();
	}), r.focus(), a();
}
//#endregion
//#region src/instances.ts
function et(e, t, n, r) {
	let i = document.createElement("li"), a = document.createElement("a");
	a.textContent = t;
	let o = e && n !== void 0 ? e.modules[G(e.index, n)] : void 0;
	return a.href = o ? `${r(o.p)}#${t}` : `#${t}`, i.append(a), i;
}
//#endregion
//#region src/tree.ts
function tt(e) {
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
function nt(e, t, n, r) {
	let i = document.createElement("ul");
	for (let [a, o] of e.children) {
		let e = t ? `${t}.${a}` : a, s = document.createElement("li"), c = document.createElement("div");
		c.className = "row";
		let l = null;
		if (o.children.size > 0) {
			l = nt(o, e, n, r), l.hidden = !(n === e || n.startsWith(`${e}.`));
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
var rt = (e) => n("li", "search-empty", e);
async function it(e, t, i) {
	let a = await I(e.root, e.usedBy).catch(() => null), o = a?.[t] ?? [];
	if (o.length === 0) {
		i.replaceChildren(rt(a ? "None" : "Index unavailable"));
		return;
	}
	i.replaceChildren(...o.map(([t, i]) => n("li", "", r("", v(e.linker, i, t), t))));
}
async function at(e, t, n, r) {
	let [i, a] = await Promise.all([I(e.root, e.version.instances).catch(() => null), e.source.data()]), o = i?.[t]?.[n] ?? [];
	if (o.length === 0) {
		r.replaceChildren(rt(i ? "None" : "Index unavailable"));
		return;
	}
	let s = a ? Ke(a.index, o) : /* @__PURE__ */ new Map();
	r.replaceChildren(...o.map((t) => et(a, t, s.get(t), e.source.href)));
}
function ot(e, t) {
	for (let n of e.querySelectorAll("details[data-fill]")) {
		let e = n.dataset.fill, r = n.dataset.name ?? "", i = n.querySelector("ul");
		!i || e === "imported-by" || n.addEventListener("toggle", () => {
			e === "used-by" ? it(t, r, i) : at(t, e === "instances" ? "instances" : "instancesFor", r, i);
		}, { once: !0 });
	}
}
function st(e) {
	let t = document.getElementById("module-tree"), n = t?.closest("details");
	!t || !n || (n.addEventListener("toggle", () => {
		I(e.root, e.version.modules).then((n) => {
			t.replaceChildren(nt(tt(n.modules), "", e.module, e.linker.at)), t.querySelector("[aria-current]")?.scrollIntoView({ block: "center" });
		});
	}, { once: !0 }), document.getElementById("nav-toggle")?.addEventListener("click", () => {
		document.body.dataset.nav === "open" && (n.open = !0);
	}));
}
//#endregion
//#region src/store-search.ts
function ct(e, t, n) {
	let r = null, i = async () => {
		let [n, r] = await Promise.all([I(e, t.modules), F(e, t.search, "bin")]), i = Ue(r);
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
var lt = "litedoc4-theme", X = [
	"auto",
	"light",
	"dark"
], ut = (e) => e !== null && X.includes(e);
function Z() {
	try {
		let e = localStorage.getItem(lt);
		return ut(e) ? e : "auto";
	} catch {
		return "auto";
	}
}
function dt(e) {
	e === "auto" ? delete document.documentElement.dataset.theme : document.documentElement.dataset.theme = e;
	let t = document.getElementById("theme-toggle");
	t && (t.title = `Theme: ${e}`, t.ariaLabel = t.title);
}
function ft() {
	dt(Z()), document.getElementById("theme-toggle")?.addEventListener("click", () => {
		let e = X[(X.indexOf(Z()) + 1) % X.length];
		try {
			localStorage.setItem(lt, e);
		} catch {}
		dt(e);
	});
}
//#endregion
//#region src/versions.ts
var pt = "missing";
function mt(e, t, n, r) {
	let i = `${e.root}${t}/`;
	if (e.kind !== "module") return i + Ne(e) + (e.kind === "search" ? n.search : "") + n.hash;
	let a = r?.find((t) => t.n === e.module);
	return a ? i + a.p + n.hash : `${i}index.html?${pt}=${encodeURIComponent(e.module)}`;
}
async function ht(e, t) {
	let n = {
		search: location.search,
		hash: location.hash
	};
	if (e.kind !== "module") return mt(e, t.name, n, null);
	let r = await I(e.root, t.data), i = await I(e.root, r.modules);
	return mt(e, t.name, n, i.modules);
}
function Q(...e) {
	let t = n("p", "results-note", ...e);
	return t.setAttribute("role", "status"), document.getElementById("content")?.prepend(t), t;
}
var gt = (e) => {
	try {
		return decodeURIComponent(e);
	} catch {
		return e;
	}
};
function _t(e) {
	let t = new URLSearchParams(location.search).get(pt);
	if (e.kind === "index" && t !== null && (Q(`The module ${t} does not exist in version ${e.version}.`), history.replaceState(history.state, "", location.pathname + location.hash)), e.kind === "module" && location.hash.length > 1) {
		let t = gt(location.hash.slice(1));
		document.getElementById(t) === null && (Q(`The declaration ${t} does not exist in version ${e.version} of ${e.module}.`), history.replaceState(history.state, "", location.pathname + location.search));
	}
}
async function $(e, t, n) {
	try {
		location.assign(await ht(e, t));
	} catch {
		n.value = e.version;
	}
}
async function vt(e) {
	let t = await fetch(new URL(`${e.root}versions.json`, location.href)).then((e) => e.ok ? e.json() : null).catch(() => null);
	if (!t || t.length === 0) return;
	let r = n("select", "versions");
	r.setAttribute("aria-label", "Version");
	for (let i of [...t].reverse()) {
		let t = n("option", "", i.name);
		t.value = i.name, t.selected = i.name === e.version, r.append(t);
	}
	r.addEventListener("change", () => {
		let n = t.find((e) => e.name === r.value);
		n && $(e, n, r);
	}), document.querySelector(".topbar .home")?.after(r);
	let i = t[t.length - 1];
	if (i && i.name !== e.version) {
		let t = n("button", "", `Go to ${i.name}`);
		t.type = "button", t.addEventListener("click", () => void $(e, i, r)), Q(`This is version ${e.version}; the newest is ${i.name}. `, t);
	}
}
//#endregion
//#region src/store-page.ts
async function yt() {
	let e = document.body, n = je(e.dataset);
	if (!n) return;
	let r = [...e.childNodes], i;
	try {
		i = await Re(n, document.title, r);
	} catch (t) {
		let n = document.createElement("p");
		n.className = "lede", n.textContent = `This page's data could not be loaded (${t instanceof Error ? t.message : String(t)}).`, e.replaceChildren(n), e.dataset.drawn = "failed";
		return;
	}
	document.title = i.title, e.classList.toggle("plain", i.plain), e.replaceChildren(...i.nodes), ft(), t();
	let a = ct(n.root, i.version, i.linker.at);
	if (n.kind === "search" && $e(a), Ze(a), n.kind === "module") {
		let t = {
			...n,
			version: i.version,
			linker: i.linker,
			source: a
		};
		ot(e, t), st(t);
	}
	_t(n), e.dataset.drawn = "1", location.hash && location.replace(location.href), vt(n);
}
yt();
//#endregion
