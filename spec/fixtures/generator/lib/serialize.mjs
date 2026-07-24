/**
 * Serialize a lang-core ParseResult (+ runtime-evaluated root) into the
 * expected-tree JSON format consumed by the Swift/Kotlin fixture runners.
 * The format is specified normatively in spec/fixtures/README.md — keep the
 * two in sync.
 */

/** True for lang-core ElementNode values. */
function isElementNode(v) {
  return !!v && typeof v === "object" && v.type === "element" && typeof v.typeName === "string";
}

/** True for lang-core AST nodes (all carry a string `k` kind tag). */
function isAstNode(v) {
  return !!v && typeof v === "object" && !Array.isArray(v) && typeof v.k === "string";
}

/** True for runtime ActionPlan values ({ steps: [...] }). */
function isActionPlan(v) {
  return !!v && typeof v === "object" && !Array.isArray(v) && Array.isArray(v.steps);
}

/** True for a single ActionStep that still carries deferred AST ({type, valueAST}). */
function isActionStep(v) {
  return !!v && typeof v === "object" && !Array.isArray(v) && "type" in v && "valueAST" in v;
}

/** Deep-serialize an AST node into plain JSON (kind tag + fields, verbatim). */
function serializeAst(node) {
  if (node === null || typeof node !== "object") return sanitizeNumber(node);
  if (Array.isArray(node)) return node.map(serializeAst);
  const out = {};
  for (const key of Object.keys(node).sort()) {
    const v = node[key];
    if (v === undefined) continue;
    out[key] = serializeAst(v);
  }
  return out;
}

/** JSON has no NaN/Infinity; encode them explicitly rather than as null. */
function sanitizeNumber(v) {
  if (typeof v === "number" && !Number.isFinite(v)) {
    return { $number: String(v) }; // "NaN" | "Infinity" | "-Infinity"
  }
  return v;
}

function serializeStep(step) {
  const out = {};
  for (const key of Object.keys(step).sort()) {
    const v = step[key];
    if (v === undefined) continue;
    out[key] = key === "valueAST" ? { $ast: serializeAst(v) } : serializeValue(v);
  }
  return out;
}

/** Serialize any evaluated prop value. */
export function serializeValue(v) {
  if (v === null || v === undefined) return null;
  if (typeof v !== "object") return sanitizeNumber(v);
  if (Array.isArray(v)) return v.map(serializeValue);
  if (isElementNode(v)) return serializeElement(v);
  if (isActionPlan(v)) return { $action: { steps: v.steps.map(serializeStep) } };
  if (isActionStep(v)) return { $action: { steps: [serializeStep(v)] } };
  if (isAstNode(v)) return { $ast: serializeAst(v) };
  // Plain data object.
  const out = {};
  for (const key of Object.keys(v).sort()) {
    const val = v[key];
    if (val === undefined) continue;
    out[key] = serializeValue(val);
  }
  return out;
}

/** Serialize an ElementNode as { component, statementId?, props, children? }. */
export function serializeElement(el) {
  const out = { component: el.typeName };
  if (el.statementId !== undefined) out.statementId = el.statementId;
  const props = {};
  let children;
  for (const key of Object.keys(el.props).sort()) {
    const val = el.props[key];
    if (val === undefined) continue;
    if (key === "children") {
      children = serializeValue(val);
    } else {
      props[key] = serializeValue(val);
    }
  }
  out.props = props;
  if (children !== undefined) out.children = children;
  return out;
}

function serializeValidationError(e) {
  const out = { code: e.code, component: e.component, path: e.path, message: e.message };
  if (e.statementId !== undefined) out.statementId = e.statementId;
  return out;
}

function serializeRuntimeError(e) {
  const out = { source: e.source, code: e.code, message: e.message };
  if (e.component !== undefined) out.component = e.component;
  if (e.statementId !== undefined) out.statementId = e.statementId;
  return out;
}

/**
 * Build the full expected-tree document.
 * @param result        ParseResult from the streaming parser
 * @param evaluatedRoot result.root after evaluateElementProps (or null)
 * @param runtimeErrors OpenUIError[] collected during prop evaluation
 */
export function serializeExpected(result, evaluatedRoot, runtimeErrors) {
  const state = {};
  for (const key of Object.keys(result.stateDeclarations ?? {}).sort()) {
    state[key] = serializeValue(result.stateDeclarations[key]);
  }
  return {
    root: evaluatedRoot ? serializeElement(evaluatedRoot) : null,
    meta: {
      incomplete: result.meta.incomplete,
      unresolved: [...result.meta.unresolved],
      errors: result.meta.errors.map(serializeValidationError),
    },
    state,
    runtimeErrors: runtimeErrors.map(serializeRuntimeError),
  };
}

/** Deterministic pretty JSON: keys are already emitted sorted upstream. */
export function stableStringify(doc) {
  return JSON.stringify(doc, null, 2) + "\n";
}
