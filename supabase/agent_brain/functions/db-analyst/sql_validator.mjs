const DEFAULT_BUILTIN_FUNCTIONS = new Set([
  'abs', 'avg', 'ceil', 'ceiling', 'count', 'date_part', 'date_trunc',
  'floor', 'greatest', 'least', 'lower', 'max', 'min', 'now',
  'nullif', 'round', 'row_number', 'sum', 'timezone', 'upper',
]);

const AGGREGATE_FUNCTIONS = new Set([
  'array_agg', 'avg', 'bool_and', 'bool_or', 'count', 'json_agg',
  'jsonb_agg', 'max', 'min', 'string_agg', 'sum',
]);

const FORBIDDEN_FUNCTIONS = new Set([
  'dblink', 'lo_export', 'lo_import', 'pg_cancel_backend', 'pg_read_binary_file',
  'pg_read_file', 'pg_sleep', 'pg_terminate_backend', 'set_config',
]);

const FORBIDDEN_STATEMENTS = new Set([
  'AlterTableStmt', 'CallStmt', 'CopyStmt', 'CreateFunctionStmt',
  'CreateSchemaStmt', 'CreateStmt', 'DeleteStmt', 'DoStmt', 'DropStmt',
  'GrantStmt', 'InsertStmt', 'ListenStmt', 'MergeStmt', 'NotifyStmt',
  'RefreshMatViewStmt', 'RevokeStmt', 'RuleStmt', 'TransactionStmt',
  'TruncateStmt', 'UpdateStmt', 'VacuumStmt', 'VariableSetStmt',
]);

function reject(code, message, details = {}) {
  return { allowed: false, code, message, ...details };
}

function walk(value, visitor) {
  if (Array.isArray(value)) {
    for (const item of value) walk(item, visitor);
    return;
  }
  if (value === null || typeof value !== 'object') return;
  visitor(value);
  for (const child of Object.values(value)) walk(child, visitor);
}

function wrappedType(value) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    return null;
  }
  const keys = Object.keys(value);
  return keys.length === 1 ? keys[0] : null;
}

function stringParts(nodes) {
  if (!Array.isArray(nodes)) return [];
  return nodes
    .map((node) => node?.String?.sval)
    .filter((value) => typeof value === 'string');
}

function integerLimit(limitCount) {
  const value = limitCount?.A_Const?.ival?.ival;
  return Number.isInteger(value) && value >= 0 ? value : null;
}

function normalizeObjectPolicy(raw) {
  const result = new Map();
  for (const [name, value] of Object.entries(raw ?? {})) {
    result.set(name.toLowerCase(), {
      sensitive: value?.sensitive === true,
      requiresGoldenQuery: value?.requiresGoldenQuery === true,
    });
  }
  return result;
}

/**
 * Validate one PostgreSQL read-only statement using the real PostgreSQL AST.
 * The parser must implement parse(sql) and scan(sql), as PgParser does.
 */
export async function validateSql(sql, policy, parser) {
  if (typeof sql !== 'string' || sql.trim() === '') {
    return reject('EMPTY_SQL', 'SQL-запрос пуст.');
  }
  if (!parser?.parse || !parser?.scan) {
    throw new TypeError('A PgParser-compatible parser is required.');
  }

  const scanResult = await parser.scan(sql);
  if (scanResult.error) {
    return reject('SCAN_ERROR', scanResult.error.message ?? 'Ошибка токенизации SQL.');
  }
  if ((scanResult.tokens ?? []).some((token) => token.text === ';')) {
    return reject('SEMICOLON_FORBIDDEN', 'Точка с запятой вне строки запрещена.');
  }

  const parseResult = await parser.parse(sql);
  if (parseResult.error) {
    return reject('PARSE_ERROR', parseResult.error.message ?? 'Ошибка разбора SQL.');
  }
  const statements = parseResult.tree?.stmts ?? [];
  if (statements.length !== 1) {
    return reject('STATEMENT_COUNT', 'Разрешён ровно один SQL-оператор.', {
      statementCount: statements.length,
    });
  }

  const root = statements[0]?.stmt;
  const rootType = wrappedType(root);
  let select;
  let isExplain = false;
  if (rootType === 'SelectStmt') {
    select = root.SelectStmt;
  } else if (rootType === 'ExplainStmt') {
    isExplain = true;
    const explain = root.ExplainStmt;
    if (wrappedType(explain?.query) !== 'SelectStmt') {
      return reject('EXPLAIN_NON_SELECT', 'EXPLAIN разрешён только для SELECT.');
    }
    const hasAnalyze = (explain.options ?? []).some(
      (option) => option?.DefElem?.defname?.toLowerCase() === 'analyze',
    );
    if (hasAnalyze) {
      return reject('EXPLAIN_ANALYZE', 'EXPLAIN ANALYZE запрещён.');
    }
    select = explain.query.SelectStmt;
  } else {
    return reject('NOT_SELECT', 'Разрешены только SELECT и EXPLAIN без ANALYZE.', {
      statementType: rootType,
    });
  }

  const allowedSchemas = new Set((policy.allowedSchemas ?? ['public'])
    .map((value) => value.toLowerCase()));
  const objectPolicy = normalizeObjectPolicy(policy.allowedObjects);
  const allowedFunctions = new Set((policy.allowedFunctions ?? [])
    .map((value) => value.toLowerCase()));
  const builtinFunctions = new Set([
    ...DEFAULT_BUILTIN_FUNCTIONS,
    ...(policy.allowedBuiltinFunctions ?? []).map((value) => value.toLowerCase()),
  ]);
  const cteNames = new Set();
  const tables = new Set();
  const functions = new Set();
  let hasStar = false;
  let hasAggregate = false;
  let forbiddenStatement = null;
  let locking = false;
  let intoClause = false;
  let nestedExplain = false;

  walk(root, (node) => {
    for (const key of Object.keys(node)) {
      if (FORBIDDEN_STATEMENTS.has(key)) forbiddenStatement ??= key;
      if (key === 'ExplainStmt' && node !== root) nestedExplain = true;
    }
    const cte = node.CommonTableExpr;
    if (typeof cte?.ctename === 'string') cteNames.add(cte.ctename.toLowerCase());
  });

  walk(root, (node) => {
    const range = node.RangeVar;
    if (range) {
      const objectName = String(range.relname ?? '').toLowerCase();
      const schemaName = String(range.schemaname ?? '').toLowerCase();
      if (schemaName === '' && cteNames.has(objectName)) return;
      tables.add(`${schemaName || 'public'}.${objectName}`);
    }
    const call = node.FuncCall;
    if (call) {
      const parts = stringParts(call.funcname).map((part) => part.toLowerCase());
      if (parts.length > 0) {
        const name = parts.at(-1);
        const schema = parts.length > 1 ? parts.at(-2) : '';
        functions.add(schema ? `${schema}.${name}` : name);
        if (AGGREGATE_FUNCTIONS.has(name)) hasAggregate = true;
      }
    }
    if (node.A_Star) hasStar = true;
    if (node.SelectStmt?.lockingClause?.length) locking = true;
    if (node.SelectStmt?.intoClause) intoClause = true;
  });

  if (forbiddenStatement) {
    return reject('MUTATING_STATEMENT', `Запрещён узел AST: ${forbiddenStatement}.`);
  }
  if (nestedExplain) return reject('NESTED_EXPLAIN', 'Вложенный EXPLAIN запрещён.');
  if (locking) return reject('ROW_LOCK', 'FOR UPDATE/FOR SHARE запрещены.');
  if (intoClause) return reject('SELECT_INTO', 'SELECT INTO запрещён.');

  for (const qualified of tables) {
    const [schema, name] = qualified.split('.', 2);
    if (!allowedSchemas.has(schema)) {
      return reject('SCHEMA_NOT_ALLOWED', `Схема ${schema} не разрешена.`, {
        object: qualified,
      });
    }
    if (!objectPolicy.has(name)) {
      return reject('OBJECT_NOT_ALLOWED', `Объект ${qualified} не входит в белый список.`, {
        object: qualified,
      });
    }
  }

  for (const qualified of functions) {
    const parts = qualified.split('.');
    const name = parts.at(-1);
    const schema = parts.length > 1 ? parts.at(-2) : '';
    if (FORBIDDEN_FUNCTIONS.has(name) || name.startsWith('lo_')) {
      return reject('FUNCTION_FORBIDDEN', `Функция ${qualified} запрещена.`, {
        function: qualified,
      });
    }
    const isBuiltin = builtinFunctions.has(name) && (schema === '' || schema === 'pg_catalog');
    const isExplicitlyAllowed = allowedFunctions.has(qualified) ||
      (schema === 'public' && allowedFunctions.has(name));
    if (!isBuiltin && !isExplicitlyAllowed) {
      return reject('FUNCTION_NOT_ALLOWED', `Функция ${qualified} не входит в белый список.`, {
        function: qualified,
      });
    }
  }

  const referencedPolicies = [...tables]
    .map((qualified) => objectPolicy.get(qualified.split('.', 2)[1]))
    .filter(Boolean);
  if (hasStar && referencedPolicies.some((item) => item.sensitive)) {
    return reject('STAR_ON_SENSITIVE_OBJECT', 'SELECT * запрещён для объекта с чувствительными полями.');
  }
  if (referencedPolicies.some((item) => item.requiresGoldenQuery) && !policy.goldenQueryCode) {
    return reject('GOLDEN_QUERY_REQUIRED', 'Для одного из объектов обязателен проверенный золотой запрос.');
  }

  const topLimit = integerLimit(select.limitCount);
  const hasRelations = tables.size > 0 || functions.size > 0;
  if (!hasAggregate && hasRelations && topLimit === null) {
    return reject('LIMIT_REQUIRED', 'Неагрегатный запрос обязан содержать числовой LIMIT.');
  }
  const maxRows = policy.maxRows ?? 200;
  if (topLimit !== null && topLimit > maxRows) {
    return reject('LIMIT_TOO_HIGH', `LIMIT превышает допустимые ${maxRows} строк.`, {
      limit: topLimit,
      maxRows,
    });
  }

  return {
    allowed: true,
    code: 'ALLOWED',
    isExplain,
    tables: [...tables].sort(),
    functions: [...functions].sort(),
    limit: topLimit,
    goldenQueryCode: policy.goldenQueryCode ?? null,
  };
}
