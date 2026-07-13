// Deterministic proportional allocation (Hamilton / largest-remainder), integer/bigint only.
//
// Splits `total` across weighted keys so that the allocations sum EXACTLY to `total` (no dust
// escapes — important for the §9 invariant that Distributor funding == sum of leaves). The
// remainder (total - sum of floors) is handed out one wei at a time to the largest fractional
// remainders, ties broken by key string ascending (fully deterministic across machines).

export interface AllocInput<K> {
  key: K;
  keyStr: string; // deterministic tie-break key
  weight: bigint; // >= 0
}

export interface AllocOutput<K> {
  alloc: Map<K, bigint>;
  unallocated: bigint; // == total when total weight is 0 (caller routes it, e.g. to treasury)
}

export function allocate<K>(total: bigint, inputs: AllocInput<K>[]): AllocOutput<K> {
  const alloc = new Map<K, bigint>();
  if (total <= 0n || inputs.length === 0) return { alloc, unallocated: total > 0n ? total : 0n };

  let W = 0n;
  for (const i of inputs) W += i.weight;
  if (W === 0n) return { alloc, unallocated: total };

  const rows = inputs.map((i) => {
    const num = total * i.weight; // exact
    const floor = num / W;
    const rem = num % W; // fractional remainder numerator
    return { key: i.key, keyStr: i.keyStr, floor, rem };
  });

  let allocated = 0n;
  for (const r of rows) {
    alloc.set(r.key, r.floor);
    allocated += r.floor;
  }
  let remainder = total - allocated; // 0 <= remainder < number of rows

  // hand out remainder to largest fractional remainders (tie-break keyStr asc)
  rows.sort((a, b) => {
    if (a.rem !== b.rem) return a.rem > b.rem ? -1 : 1;
    return a.keyStr < b.keyStr ? -1 : a.keyStr > b.keyStr ? 1 : 0;
  });
  let idx = 0;
  while (remainder > 0n && idx < rows.length) {
    const r = rows[idx]!;
    alloc.set(r.key, (alloc.get(r.key) ?? 0n) + 1n);
    remainder -= 1n;
    idx += 1;
  }
  // if remainder still > 0 (fewer rows than remainder — impossible since remainder < rows),
  // it stays unallocated; report it.
  return { alloc, unallocated: remainder };
}
