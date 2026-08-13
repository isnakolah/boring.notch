// Bounded App-Pack descriptor validation.  This grammar is mirrored in
// tools/packctl and TutorKit: literals, ^/$ anchors, character classes, and
// alternation only.  It deliberately excludes engine-specific regex features.

export const MAX_MATCHER_BYTES = 128;
const UNSAFE_MATCHER_TOKENS = new Set(["\\", "?", "*", "+", "(", ")", "{", "}"]);
const FORBIDDEN_COORDINATE_KEYS = new Set([
  "x", "y", "left", "top", "width", "height", "coordinate", "coordinates", "screen_x", "screen_y", "bounds", "frame",
]);

function object(value, name) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new TypeError(`${name} must be an object`);
  return value;
}

function string(value, name, maximum = 256) {
  if (typeof value !== "string" || !value.trim() || Buffer.byteLength(value, "utf8") > maximum) {
    throw new TypeError(`${name} must be a non-empty UTF-8 string of at most ${maximum} bytes`);
  }
  return value;
}

function identifier(value, name) {
  string(value, name);
  if (!/^[a-z0-9][a-z0-9._-]*$/.test(value)) throw new TypeError(`${name} must be a stable semantic identifier`);
  return value;
}

function onlyKeys(value, allowed, name) {
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) throw new TypeError(`${name} contains unsupported field ${key}`);
  }
}

export function findDescriptorCoordinatePath(value, path = []) {
  if (Array.isArray(value)) {
    for (let index = 0; index < value.length; index += 1) {
      const found = findDescriptorCoordinatePath(value[index], [...path, String(index)]);
      if (found) return found;
    }
    return null;
  }
  if (!value || typeof value !== "object") return null;
  for (const [key, child] of Object.entries(value)) {
    const next = [...path, key];
    if (FORBIDDEN_COORDINATE_KEYS.has(key.toLowerCase())) return next.join(".");
    const found = findDescriptorCoordinatePath(child, next);
    if (found) return found;
  }
  return null;
}

export function validateSafeMatcher(value, name = "matcher") {
  const matcher = object(value, name);
  onlyKeys(matcher, new Set(["pattern", "case_insensitive"]), name);
  const pattern = string(matcher.pattern, `${name}.pattern`, MAX_MATCHER_BYTES);
  if (matcher.case_insensitive !== undefined && typeof matcher.case_insensitive !== "boolean") {
    throw new TypeError(`${name}.case_insensitive must be a boolean`);
  }
  for (const character of pattern) {
    if (UNSAFE_MATCHER_TOKENS.has(character)) throw new TypeError(`${name}.pattern contains a forbidden regex operator`);
  }
  for (const alternative of pattern.split("|")) {
    if (!alternative) throw new TypeError(`${name}.pattern alternation branches must not be empty`);
    if ((alternative.match(/\^/g) || []).length > 1 || (alternative.match(/\$/g) || []).length > 1) {
      throw new TypeError(`${name}.pattern anchors may appear at most once per alternation branch`);
    }
    if (alternative.includes("^") && !alternative.startsWith("^")) {
      throw new TypeError(`${name}.pattern ^ is permitted only at the start of an alternation branch`);
    }
    if (alternative.includes("$") && !alternative.endsWith("$")) {
      throw new TypeError(`${name}.pattern $ is permitted only at the end of an alternation branch`);
    }
    for (let index = 0; index < alternative.length; index += 1) {
      if (alternative[index] === "[") {
        const closing = alternative.indexOf("]", index + 1);
        if (closing < 0 || closing === index + 1) throw new TypeError(`${name}.pattern character classes must be non-empty and closed`);
        const contents = alternative.slice(index + 1, closing);
        if (/[\[\^$|]/.test(contents)) throw new TypeError(`${name}.pattern character class contains an unsupported token`);
        index = closing;
      } else if (alternative[index] === "]") {
        throw new TypeError(`${name}.pattern character class is not opened`);
      }
    }
  }
  return matcher;
}

export function safeMatcherMatches(matcher, text) {
  const checked = validateSafeMatcher(matcher);
  return new RegExp(checked.pattern, checked.case_insensitive ? "i" : "").test(String(text));
}

function validateAccessibility(value, name) {
  const resolver = object(value, name);
  if (Object.keys(resolver).length !== 1 || !Array.isArray(resolver.candidates) || !resolver.candidates.length || resolver.candidates.length > 16) {
    throw new TypeError(`${name} must contain 1..16 candidates only`);
  }
  for (const [index, rawCandidate] of resolver.candidates.entries()) {
    const candidate = object(rawCandidate, `${name}.candidates.${index}`);
    onlyKeys(candidate, new Set(["role", "label_matcher", "description_matcher", "help_matcher"]), `${name}.candidates.${index}`);
    string(candidate.role, `${name}.candidates.${index}.role`, 80);
    const matchers = ["label_matcher", "description_matcher", "help_matcher"].filter((field) => candidate[field] !== undefined);
    if (!matchers.length) throw new TypeError(`${name}.candidates.${index} requires at least one authored matcher`);
    for (const field of matchers) validateSafeMatcher(candidate[field], `${name}.candidates.${index}.${field}`);
  }
}

function validateBridge(value, name) {
  const resolver = object(value, name);
  if (Object.keys(resolver).length !== 1) throw new TypeError(`${name} must contain selector only`);
  const selector = object(resolver.selector, `${name}.selector`);
  const entries = Object.entries(selector);
  if (!entries.length || entries.length > 16) throw new TypeError(`${name}.selector must contain 1..16 fields`);
  for (const [key, item] of entries) {
    string(key, `${name}.selector key`, 64);
    if (!["string", "number", "boolean"].includes(typeof item) || !Number.isFinite(item) && typeof item === "number") {
      throw new TypeError(`${name}.selector.${key} must be a finite scalar`);
    }
    if (typeof item === "string") string(item, `${name}.selector.${key}`, 128);
  }
}

function validateVisual(value, name) {
  const visual = object(value, name);
  onlyKeys(visual, new Set(["icon", "relative_to", "layout_hint", "constraints", "text_matcher"]), name);
  if (!Object.keys(visual).length) throw new TypeError(`${name} must not be empty`);
  for (const field of ["icon", "relative_to", "layout_hint"]) {
    if (visual[field] !== undefined) string(visual[field], `${name}.${field}`, 128);
  }
  if (visual.constraints !== undefined && (!Array.isArray(visual.constraints) || visual.constraints.length > 8 || !visual.constraints.every((item) => item === "visible" || item === "enabled"))) {
    throw new TypeError(`${name}.constraints must contain at most eight known visual constraints`);
  }
  if (visual.text_matcher !== undefined) validateSafeMatcher(visual.text_matcher, `${name}.text_matcher`);
}

function validateConfidence(value, name) {
  const confidence = object(value, name);
  if (Object.keys(confidence).length !== 2 || !("point" in confidence) || !("act" in confidence)) {
    throw new TypeError(`${name} must contain exactly point and act`);
  }
  for (const field of ["point", "act"]) {
    if (typeof confidence[field] !== "number" || !Number.isFinite(confidence[field]) || confidence[field] <= 0 || confidence[field] > 1) {
      throw new TypeError(`${name}.${field} must be a finite number in (0, 1]`);
    }
  }
}

export function validateTargetDescriptor(value, name = "target_descriptor") {
  const target = object(value, name);
  onlyKeys(target, new Set(["id", "kind", "title", "aliases", "app_versions", "source_refs", "region", "resolve", "neighbor_constraints", "minimum_confidence", "source_file"]), name);
  identifier(target.id, `${name}.id`);
  if (target.kind !== "ui_target") throw new TypeError(`${name}.kind must be ui_target`);
  string(target.title, `${name}.title`);
  if (target.aliases !== undefined && (!Array.isArray(target.aliases) || target.aliases.length > 32 || !target.aliases.every((item) => typeof item === "string" && item.trim()))) {
    throw new TypeError(`${name}.aliases must contain at most 32 non-empty strings`);
  }
  if (target.region !== undefined) identifier(target.region, `${name}.region`);
  const resolve = object(target.resolve, `${name}.resolve`);
  onlyKeys(resolve, new Set(["accessibility", "bridge", "visual"]), `${name}.resolve`);
  if (!Object.keys(resolve).length) throw new TypeError(`${name}.resolve requires a resolver branch`);
  if (resolve.accessibility !== undefined) validateAccessibility(resolve.accessibility, `${name}.resolve.accessibility`);
  if (resolve.bridge !== undefined) validateBridge(resolve.bridge, `${name}.resolve.bridge`);
  if (resolve.visual !== undefined) validateVisual(resolve.visual, `${name}.resolve.visual`);
  if (target.neighbor_constraints !== undefined) {
    const neighbors = object(target.neighbor_constraints, `${name}.neighbor_constraints`);
    if (Object.keys(neighbors).length !== 1 || !Array.isArray(neighbors.expected) || !neighbors.expected.length || neighbors.expected.length > 8) {
      throw new TypeError(`${name}.neighbor_constraints must contain 1..8 expected labels only`);
    }
    neighbors.expected.forEach((item, index) => identifier(item, `${name}.neighbor_constraints.expected.${index}`));
  }
  validateConfidence(target.minimum_confidence, `${name}.minimum_confidence`);
  const coordinate = findDescriptorCoordinatePath(target);
  if (coordinate) throw new TypeError(`${name}.${coordinate} is coordinate-bearing and forbidden`);
  return target;
}

function validateScalar(value, name) {
  if (value === null || typeof value === "boolean" || typeof value === "string" || Number.isInteger(value) || typeof value === "number" && Number.isFinite(value)) {
    if (typeof value === "string") string(value, name, 128);
    return;
  }
  throw new TypeError(`${name} must be a finite scalar`);
}

export function validateDetectorDescriptor(value, name = "expected_state") {
  const detector = object(value, name);
  onlyKeys(detector, new Set(["id", "kind", "title", "aliases", "app_versions", "source_refs", "provider", "query", "source_file"]), name);
  identifier(detector.id, `${name}.id`);
  if (detector.kind !== "detector") throw new TypeError(`${name}.kind must be detector`);
  string(detector.title, `${name}.title`);
  if (!["blender_bridge", "accessibility"].includes(detector.provider)) throw new TypeError(`${name}.provider must be blender_bridge or accessibility`);
  const query = object(detector.query, `${name}.query`);
  if (detector.provider === "accessibility") {
    if (Object.keys(query).length !== 3 || !Object.hasOwn(query, "target") || !Object.hasOwn(query, "attribute") || !Object.hasOwn(query, "equals")) {
      throw new TypeError(`${name}.query accessibility detectors require target, attribute, and equals`);
    }
    identifier(query.target, `${name}.query.target`);
    if (!["selected", "enabled", "visible"].includes(query.attribute) || typeof query.equals !== "boolean") {
      throw new TypeError(`${name}.query accessibility detector has an unsupported attribute or expected value`);
    }
  } else {
    onlyKeys(query, new Set(["path", "equals", "contains", "any"]), `${name}.query`);
    const segments = string(query.path, `${name}.query.path`, 128).split(".");
    if (!segments.length || segments.length > 8 || !segments.every((item) => /^[A-Za-z_][A-Za-z0-9_]*$/.test(item))) {
      throw new TypeError(`${name}.query.path must contain 1..8 bounded object-path segments`);
    }
    const operators = ["equals", "contains", "any"].filter((field) => Object.hasOwn(query, field));
    if (operators.length !== 1) throw new TypeError(`${name}.query requires exactly one operator`);
    if (operators[0] === "any") {
      const expected = object(query.any, `${name}.query.any`);
      const entries = Object.entries(expected);
      if (!entries.length || entries.length > 8) throw new TypeError(`${name}.query.any must contain 1..8 fields`);
      entries.forEach(([key, item]) => { string(key, `${name}.query.any key`, 64); validateScalar(item, `${name}.query.any.${key}`); });
    } else {
      validateScalar(query[operators[0]], `${name}.query.${operators[0]}`);
    }
  }
  const coordinate = findDescriptorCoordinatePath(detector);
  if (coordinate) throw new TypeError(`${name}.${coordinate} is coordinate-bearing and forbidden`);
  return detector;
}

export function canonicalJSONString(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJSONString).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJSONString(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}
