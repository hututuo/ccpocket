import fs from 'node:fs';
import * as oldP from '../packages/conversation-contract/src/semantic-primitives.mjs';
import * as newP from '../../ccpocket-b1-semantic-fix-20260831/packages/conversation-contract/src/semantic-primitives.mjs';

const vectorPath = 'docs/design/codex-kernel-v4/contracts/vectors/phone-core-vectors.json';
const document = JSON.parse(fs.readFileSync(vectorPath, 'utf8'));

const equal = (left, right) => JSON.stringify(left) === JSON.stringify(right);
const clone = (value) => value === undefined ? undefined : structuredClone(value);

function inferOptions(snapshot) {
  const rows = snapshot.pages.flatMap((page) => page.body?.items ?? []);
  const items = rows.filter((row) => row.rowKind === 'TIMELINE_ITEM').map((row) => row.timelineItem);
  const spines = rows.filter((row) => row.rowKind === 'TURN_SPINE').map((row) => row.turnSpine);
  const firstItem = items[0];
  const firstPayloads = firstItem?.payloads;
  const firstText = firstPayloads?.find((payload) => payload.kind === 'text')?.text;
  const materializationId = snapshot.beginFrame.block.subject.materializationId;
  const empty = snapshot.pages.length === 0;
  const itemCounts = spines.filter((spine) => spine.turnRef.turnId === 'turn-1').map((spine) => spine.itemCount);
  return {
    materializationId,
    thread: snapshot.beginFrame.subject.threadRef,
    empty,
    pageCountOverride: snapshot.beginFrame.pageCount,
    itemCountOverride: empty ? undefined : spines.length || undefined,
    itemsPerTurn: itemCounts[0] ?? 1,
    itemText: firstText ?? 'hello',
    payloadsOverride: firstPayloads,
    baseHeadVersion: snapshot.commit.baseHeadVersion,
    subscriptionId: snapshot.beginFrame.message.subscriptionId,
    streamId: snapshot.beginFrame.message.streamId,
    timelineOrdinalOverride: firstItem?.timelineOrdinal,
    turnOrdinalOverride: spines[0]?.turnOrdinal,
    itemOrdinalOverride: firstItem?.itemOrdinal,
    groupTurns: spines.some((spine) => spine.predecessorTurnRef !== null),
    withBetweenGap: snapshot.pages.some((page) => page.body.gaps.some((gap) => gap.target?.targetKind === 'BETWEEN')),
    indexOnly: snapshot.beginFrame.begin.payload.readBody.itemsView === 'notLoaded',
  };
}

function overlay(oldValue, oldBaseline, newBaseline) {
  if (equal(oldValue, oldBaseline)) return clone(newBaseline);
  if (Array.isArray(oldValue) && Array.isArray(oldBaseline) && Array.isArray(newBaseline)) {
    if (oldValue.length !== oldBaseline.length || oldBaseline.length !== newBaseline.length) return clone(oldValue);
    return oldValue.map((value, index) => overlay(value, oldBaseline[index], newBaseline[index]));
  }
  if (oldValue && oldBaseline && newBaseline && typeof oldValue === 'object' && typeof oldBaseline === 'object' && typeof newBaseline === 'object' && !Array.isArray(oldValue) && !Array.isArray(oldBaseline) && !Array.isArray(newBaseline)) {
    const result = clone(newBaseline);
    for (const key of Object.keys(oldBaseline)) {
      if (!Object.hasOwn(oldValue, key)) delete result[key];
    }
    for (const key of Object.keys(oldValue)) {
      result[key] = Object.hasOwn(oldBaseline, key)
        ? overlay(oldValue[key], oldBaseline[key], newBaseline[key])
        : clone(oldValue[key]);
    }
    return result;
  }
  return clone(oldValue);
}

function refreshSnapshots(value) {
  if (!value || typeof value !== 'object') return value;
  if (value.beginFrame && Array.isArray(value.pages) && value.commit) {
    const options = inferOptions(value);
    const oldBaseline = oldP.materialization(options);
    const newBaseline = newP.materialization(options);
    return overlay(value, oldBaseline, newBaseline);
  }
  if (Array.isArray(value)) return value.map(refreshSnapshots);
  return Object.fromEntries(Object.entries(value).map(([key, entry]) => [key, refreshSnapshots(entry)]));
}

document.vectors = refreshSnapshots(document.vectors);
function replaceDigest(value) {
  if (value === '2426fc5ae572756afe1f0877a01bd6ea388a40b15eda79ccfeb4ab8f1de326e9') return '39c54f5b03d4f45e68418896d6e6b743cd85b86411ece8db9e7d177f2dd52a85';
  if (Array.isArray(value)) return value.map(replaceDigest);
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, entry]) => [key, replaceDigest(entry)]));
  return value;
}
document.vectors = replaceDigest(document.vectors);
fs.writeFileSync(vectorPath, `${JSON.stringify(document, null, 2)}\n`);
