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
var l = (e) => c(e).join("/"), u = (e) => `${l(e)}.html`, d = (e, t) => `${e}/${l(t)}.lean`, ee = (e, t, n) => d(e, t) + (n ? `#L${n[0]}-L${n[1]}` : ""), f = (e) => e.slice(e.lastIndexOf(".") + 1);
function te(e, t) {
	let n = (e) => t.includes(e);
	if (e === "definition" || e === "instance") {
		let t = n("unsafe") ? "unsafe " : "", r = n("noncomputable") ? "noncomputable " : "", i = e === "instance" ? "instance" : n("abbrev") ? "abbrev" : "def";
		return t + r + i;
	}
	return e === "axiom" && n("unsafe") ? "unsafe axiom" : e === "opaque" && n("partial") ? "partial def" : e === "opaque" && n("unsafe") ? "unsafe opaque" : e === "inductive" && n("unsafe") ? "unsafe inductive" : e === "class_inductive" ? "class inductive" : e;
}
function p(e) {
	return e === "definition" ? "def" : e === "class_inductive" ? "class" : e === "constructor" ? "ctor" : e;
}
var ne = (e) => String(e).replace(/\B(?=(\d{3})+$)/g, ","), re = "foundational_types.html", m = (e, t, n) => e.at(u(t) + (n === null ? "" : `#${n}`)), ie = (e) => typeof e[0] == "number";
function h(e, t, n) {
	if (ie(n)) {
		let t = e.bases[e.roots[n[0]] ?? ""];
		return t === void 0 ? null : ee(t, n[1], n.length === 4 ? [n[2], n[3]] : null);
	}
	let r = n;
	return m(e, r[0], r.length === 1 ? t : r[1]);
}
function g(e, t, n) {
	if (!Object.hasOwn(t, n)) return null;
	let r = t[n];
	return r === void 0 ? null : h(e, n, r);
}
//#endregion
//#region src/spans.ts
var ae = (e) => typeof e == "string" ? [e, []] : e;
function oe(e, t, n) {
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
function _(e, t) {
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
function se(e, t, n) {
	if (e.startsWith("##")) {
		let r = e.slice(2);
		return n(r) ?? t(`find/?pattern=${r}#doc`);
	}
	return e.startsWith("#") || e.startsWith("http") ? e : t(e);
}
function v(e, t, n) {
	let i = (e) => g(n, t, e), a = o(e);
	for (let e of a.querySelectorAll("a[href]")) e.setAttribute("href", se(e.getAttribute("href") ?? "", n.at, i));
	for (let e of [...a.querySelectorAll("w")]) {
		let t = _(e.textContent ?? "", i), n = [];
		t.before && n.push(document.createTextNode(t.before)), t.href !== null && n.push(r("", t.href, t.linked)), e.replaceWith(...n);
	}
	return a;
}
//#endregion
//#region src/draw-module.ts
function y(e, t) {
	let [n, i] = ae(t);
	return oe(n, i, (t) => t.length === 2 ? e.l.at(re) : g(e.l, e.page.names, t[2])).map((e) => e.href === null ? document.createTextNode(e.text) : r("", e.href, e.text));
}
var b = (e, t) => v(t, e.page.words, e.l);
function x(e, t) {
	return (t ?? []).flatMap(([t, r]) => [n("span", t ? "binder implicit" : "binder", n("span", "fn", ...y(e, r))), document.createTextNode("\n")]);
}
function S(e, t) {
	let r = n("div", "sig", ...x(e, t.b));
	return (t.k === "structure" || t.k === "class") && t.p && t.p.length > 0 && (r.append(n("span", "extends", "extends"), " "), t.p.forEach(([t, a], o) => {
		o > 0 && r.append(", "), r.append(i(n("span", "", ...y(e, a)), t));
	})), r.append(n("span", "colon", " :"), n("div", "sig-type", ...y(e, t.t))), r;
}
function ce(e, t, i) {
	let o = i ? `#L${i[0]}-L${i[1]}` : "";
	return n("header", "decl-head", n("span", "kind", te(t.k, t.mods ?? [])), n("h2", "decl-name", r("break_within", m(e.l, e.page.module, t.n), ...a(t.n))), r("src", e.sourceUrl + o, "source"));
}
function C(e, ...t) {
	let r = n("span", "flag", ...t);
	return r.dataset.flag = e, r;
}
function le(e, t) {
	let i = [];
	if (t.sorry === "direct" && i.push(C("sorry-direct", "uses ", n("code", "", "sorry"))), t.sorry === "transitive" && i.push(C("sorry-transitive", "depends on ", n("code", "", "sorry"))), t.gen) {
		let [a, o] = t.gen, s = g(e.l, e.page.names, o), c = n("code", "", o);
		i.push(C("generated", "realized by ", n("code", "", `@[${a}]`), " from ", s === null ? c : r("", s, c)));
	}
	return i.length === 0 ? null : n("div", "flags", ...i);
}
function w(e, t, r) {
	let i = n("details", "extra", n("summary", "", r), n("ul", ""));
	return i.dataset.fill = e, i.dataset.name = t, i;
}
function ue(e, t) {
	if (!t.eq && !t.eqOmitted) return null;
	let r = n("ul", "equations");
	t.eqOmitted && r.append(n("li", "", "One or more equations did not get rendered due to their size."));
	for (let i of t.eq ?? []) r.append(n("li", "", ...y(e, i)));
	return n("details", "extra", n("summary", "", "Equations"), r);
}
function T(e, t, r) {
	return n("div", "field-sig", t, ...x(e, r.b), n("span", "colon", " : "), ...y(e, r.t));
}
function E(e, t, r) {
	return r.doc && t.append(n("div", "field-doc", b(e, r.doc))), t;
}
function de(e, t, a) {
	let o = f(a.n);
	if (!a.inh) return E(e, i(n("li", "field", T(e, n("span", "field-name", o), a)), a.n), a);
	let s = g(e.l, e.page.names, a.n), c = n("li", "field inherited", T(e, s === null ? n("span", "field-name", o) : r("field-name", s, o), a));
	return a.id && (c.id = `${t.n}.${o}`), c;
}
function fe(e, t) {
	let r = t.ctor ?? `${t.n}.mk`, a = f(r), o = [];
	return a !== "mk" && o.push(n("p", "ctor-note", "constructor ", n("code", "", a))), o.push(i(n("ul", "fields", ...(t.f ?? []).map((n) => de(e, t, n))), r)), o;
}
function D(e, t) {
	let r = t.c ?? [];
	return r.length === 0 ? [] : [n("ul", "ctors", ...r.map((t) => E(e, i(n("li", "ctor", T(e, n("span", "field-name", f(t.n)), t)), t.n), t)))];
}
function O(e, t, r) {
	let a = i(n("section", "decl"), t.n);
	a.dataset.kind = p(t.k), a.append(ce(e, t, r));
	let o = le(e, t);
	o && a.append(o), t.attrs && t.attrs.length > 0 && a.append(n("div", "attrs", `@[${t.attrs.join(", ")}]`)), a.append(S(e, t)), t.doc && a.append(n("div", "doc", b(e, t.doc)));
	let s = [], c = () => {
		let n = ue(e, t);
		n && s.push(n);
	};
	return t.k === "structure" || t.k === "class" ? (a.append(...fe(e, t)), s.push(t.k === "class" ? w("instances", t.n, "Instances") : w("instances-for", t.n, "Instances For"))) : t.k === "definition" ? (c(), s.push(w("instances-for", t.n, "Instances For"))) : t.k === "instance" ? c() : t.k === "inductive" ? (a.append(...D(e, t)), s.push(w("instances-for", t.n, "Instances For"))) : t.k === "class_inductive" && (a.append(...D(e, t)), s.push(w("instances", t.n, "Instances"))), s.push(w("used-by", t.n, "Used by")), a.append(...s), a;
}
function k(e, t) {
	let i = e.l.bases[c(t)[0] ?? ""];
	return n("li", "", i === void 0 ? t : r("", d(i, t), t));
}
function A(e) {
	let t = e.page.imports, r = n("summary", "", "Imports");
	t.length > 0 && r.append(" ", n("span", "count", String(t.length)));
	let i = n("details", "imports", r, n("ul", "", ...t.map((t) => k(e, t)))), a = n("details", "imports", n("summary", "", "Imported by"), n("ul", ""));
	return a.dataset.fill = "imported-by", a.hidden = !0, n("div", "modmeta", i, a);
}
var j = (e) => "moddoc" in e;
function M(e) {
	return e.flatMap((e) => j(e) ? [] : [e.n]);
}
function N(e) {
	let t = e.page.module, i = d(e.version.source, t), o = {
		l: e.linker,
		page: e.page,
		sourceUrl: i
	}, s = n("main", "content", n("div", "modhead", n("h1", "", ...a(t)), n("p", "modactions", r("src", i, "source"))), A(o));
	return e.content.forEach((t, r) => {
		if (j(t)) {
			s.append(n("div", "moddoc", b(o, t.moddoc)));
			return;
		}
		let i = e.page.lines[r];
		s.append(O(o, t, i === 0 || i === void 0 ? null : i));
	}), s.querySelectorAll("a[data-cite]").forEach((e, t) => {
		e.removeAttribute("data-cite"), e.id = `_backref_${t}`;
	}), s;
}
function P(e, t, i, a) {
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
var F = "API documentation for every module of this package, generated from the compiled environment. Declarations link to their pinned source; an import of a dependency links to that dependency's source at the revision this package is built against.";
function I(e, t) {
	return n("div", "", n("dt", "", e), n("dd", "", t));
}
function L(e, t, i, o) {
	let s = [n("div", "modhead", n("h1", "", t.title), n("p", "lede", F))];
	if (o) {
		let t = {
			...e,
			roots: o.roots
		};
		s.push(n("div", "intro doc", v(o.html, o.words, t)));
	}
	let c = n("dl", "stats", I("Modules", ne(i.length)));
	return t.lean && c.append(I("Lean", t.lean)), s.push(c, n("h2", "section-title", "Modules"), n("ul", "modlist", ...i.map((t) => n("li", "", r("", e.at(t.p), ...a(t.n)))))), s;
}
function R(e, t, [n, i, a]) {
	let o = r("", m(e, n, `_backref_${i}`), `[${t}]`);
	return o.title = `File: ${n}${a ? `\nLocation: ${a}` : ""}`, [document.createTextNode(" "), o];
}
function z(e, t) {
	let a = t.map((t) => {
		let a = `ref_${t.key}`, s = i(n("li", "", r("", `#${a}`, t.tag), " ", o(t.html)), a);
		return t.by.length > 0 && s.append(n("small", "", ...t.by.flatMap((t, n) => R(e, n + 1, t)))), s;
	});
	return [n("div", "modhead", n("h1", "", "References")), n("div", "doc", n("ul", "", ...a))];
}
//#endregion
//#region src/frame.ts
var B = "<svg viewBox=\"0 0 20 20\" aria-hidden=\"true\"><path d=\"M3 5h14M3 10h14M3 15h14\"/></svg>", V = "<svg viewBox=\"0 0 20 20\" aria-hidden=\"true\"><path d=\"M10 3a7 7 0 1 0 7 7 5.5 5.5 0 0 1-7-7z\"/></svg>";
function H(e, t, r) {
	let a = i(n("button", "iconbtn", o(r)), e);
	return a.setAttribute("aria-label", t), a;
}
function U(e, t) {
	let a = n("header", "topbar");
	if (t) {
		let e = H("nav-toggle", "Modules", B);
		e.setAttribute("aria-expanded", "false"), e.setAttribute("aria-controls", "sidebar"), a.append(e);
	}
	let o = i(n("input", ""), "search-input");
	o.type = "search", o.name = "q", o.autocomplete = "off", o.spellcheck = !1, o.placeholder = "Search declarations", o.setAttribute("aria-label", "Search declarations");
	let s = i(n("ul", "search-results"), "search-results");
	s.hidden = !0;
	let c = n("form", "search", o, s);
	return c.setAttribute("role", "search"), c.setAttribute("action", e.at("search.html")), a.append(r("home", e.at("index.html"), e.title), c, H("theme-toggle", "Theme", V)), a;
}
var W = () => r("skip", "#content", "Skip to content");
function G(e, ...t) {
	let r = i(n("main", "content", ...t), "content");
	return [
		W(),
		U(e, !1),
		n("div", "shell", r)
	];
}
function pe(e, t, o) {
	let s = i(n("div", "scrim"), "scrim");
	s.hidden = !0;
	let c = i(n("nav", "sidebar"), "sidebar");
	if (c.setAttribute("aria-label", "Navigation"), t.length > 0) {
		let e = n("ul", "toc", ...t.map((e) => n("li", "", r("", `#${e}`, ...a(e)))));
		c.append(n("section", "side", n("h2", "side-title", "On this page"), e));
	}
	return c.append(n("section", "side", n("h2", "side-title", "Modules"), i(n("div", "tree"), "module-tree"))), [
		W(),
		U(e, !0),
		n("div", "shell", s, c, i(o, "content"))
	];
}
//#endregion
//#region src/gzip.ts
var me = (e) => e.length >= 2 && e[0] === 31 && e[1] === 139;
async function he(e) {
	if (!me(e)) return e;
	let t = new Blob([e]).stream().pipeThrough(new DecompressionStream("gzip"));
	return new Uint8Array(await new Response(t).arrayBuffer());
}
//#endregion
//#region src/store-data.ts
var ge = new TextDecoder(), K = /* @__PURE__ */ new Map(), _e = (e, t) => `d/${e}.${t}.gz`;
function ve(e, t, n) {
	let r = new URL(e + _e(t, n), location.href).href, i = K.get(r);
	return i || (i = fetch(r).then((e) => e.ok ? e.arrayBuffer() : Promise.reject(/* @__PURE__ */ Error(`${e.status} ${r}`))).then((e) => he(new Uint8Array(e))), K.set(r, i)), i;
}
async function q(e, t) {
	return JSON.parse(ge.decode(await ve(e, t, "json")));
}
//#endregion
//#region src/route.ts
function ye(e) {
	let { root: t, version: n, data: r } = e;
	if (t === void 0 || n === void 0 || r === void 0) return null;
	let i = {
		root: t,
		version: n,
		data: r
	};
	return e.page === void 0 ? e.references === void 0 ? {
		...i,
		kind: "index"
	} : {
		...i,
		kind: "references",
		references: e.references
	} : {
		...i,
		kind: "module",
		page: e.page,
		usedBy: e.usedBy ?? ""
	};
}
var be = (e) => `${e.root}${e.version}/`, J = (e, t, n) => {
	let r = be(e);
	return {
		at: (e) => r + e,
		roots: n,
		bases: t.roots
	};
}, Y = (e, t) => t && t !== e ? `${e} · ${t}` : e;
async function xe(e) {
	let [t, n] = await Promise.all([q(e.root, e.data), q(e.root, e.page)]), r = n.content === null ? [] : await q(e.root, n.content), i = J(e, t, n.roots), a = N({
		linker: i,
		version: t,
		page: n,
		content: r
	});
	a.querySelector(".modmeta .imports:not([data-fill])")?.addEventListener("toggle", () => {
		q(e.root, t.modules).then((e) => P(a, i, e.modules, n.module));
	}, { once: !0 });
	let o = i.at;
	return {
		title: Y(n.module, t.title),
		nodes: pe({
			title: t.title,
			at: o
		}, M(r), a),
		plain: !1
	};
}
async function Se(e) {
	let t = await q(e.root, e.data), [n, r] = await Promise.all([q(e.root, t.modules), t.front === null ? null : q(e.root, t.front)]), i = J(e, t, []);
	return {
		title: t.title,
		nodes: G({
			title: t.title,
			at: i.at
		}, ...L(i, t, n.modules, r)),
		plain: !0
	};
}
async function Ce(e) {
	let [t, n] = await Promise.all([q(e.root, e.data), q(e.root, e.references)]), r = J(e, t, []);
	return {
		title: Y("References", t.title),
		nodes: G({
			title: t.title,
			at: r.at
		}, ...z(r, n)),
		plain: !0
	};
}
function we(e) {
	return e.kind === "module" ? xe(e) : e.kind === "references" ? Ce(e) : Se(e);
}
//#endregion
//#region src/theme-key.ts
var X = "litedoc4-theme", Z = [
	"auto",
	"light",
	"dark"
], Te = (e) => e !== null && Z.includes(e);
function Q() {
	try {
		let e = localStorage.getItem(X);
		return Te(e) ? e : "auto";
	} catch {
		return "auto";
	}
}
function $(e) {
	e === "auto" ? delete document.documentElement.dataset.theme : document.documentElement.dataset.theme = e;
	let t = document.getElementById("theme-toggle");
	t && (t.title = `Theme: ${e}`, t.ariaLabel = t.title);
}
function Ee() {
	$(Q()), document.getElementById("theme-toggle")?.addEventListener("click", () => {
		let e = Z[(Z.indexOf(Q()) + 1) % Z.length];
		try {
			localStorage.setItem(X, e);
		} catch {}
		$(e);
	});
}
//#endregion
//#region src/store-page.ts
async function De() {
	let e = document.body, n = ye(e.dataset);
	if (n) {
		try {
			let t = await we(n);
			document.title = t.title, e.classList.toggle("plain", t.plain), e.replaceChildren(...t.nodes);
		} catch (t) {
			let n = document.createElement("p");
			n.className = "lede", n.textContent = `This page's data could not be loaded (${t instanceof Error ? t.message : String(t)}).`, e.replaceChildren(n), e.dataset.drawn = "failed";
			return;
		}
		Ee(), t(), e.dataset.drawn = "1", location.hash && location.replace(location.href);
	}
}
De();
//#endregion
