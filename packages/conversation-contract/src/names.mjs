const DART_RESERVED = new Set([
  'assert', 'break', 'case', 'catch', 'class', 'const', 'continue', 'default',
  'do', 'else', 'enum', 'extends', 'false', 'final', 'finally', 'for', 'if',
  'in', 'is', 'new', 'null', 'rethrow', 'return', 'super', 'switch', 'this',
  'throw', 'true', 'try', 'var', 'void', 'while', 'with',
]);

export function pascalName(value) {
  const words = value
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .split(/[^A-Za-z0-9]+/)
    .filter(Boolean);
  let result = words.map((word) => `${word[0].toUpperCase()}${word.slice(1)}`).join('');
  if (!result) result = 'Generated';
  if (/^[0-9]/.test(result)) result = `N${result}`;
  return result;
}

export function dartMemberName(value) {
  const pascal = pascalName(value);
  let result = `${pascal[0].toLowerCase()}${pascal.slice(1)}`;
  if (DART_RESERVED.has(result)) result = `${result}Value`;
  return result;
}

export function enumMemberName(value) {
  return dartMemberName(value);
}
