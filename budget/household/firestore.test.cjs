const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const {
  initializeTestEnvironment, assertSucceeds, assertFails,
} = require('@firebase/rules-unit-testing');
const {
  collection, doc, getDoc, getDocs, setDoc, updateDoc, deleteDoc, writeBatch,
  serverTimestamp, Timestamp,
} = require('firebase/firestore');

const projectId = 'demo-cashew-household';
const spaceId = '00000000-0000-4000-8000-000000000001';
const account1 = '00000000-0000-4000-8000-000000000002';
const account2 = '00000000-0000-4000-8000-000000000003';
const space = `households/${spaceId}`;
let env;

const actor = (uid, email, verified = true) =>
  env.authenticatedContext(uid, { email, email_verified: verified }).firestore();
const link = (uid) => `householdUsers/${uid}/links/${spaceId}`;
const member = (uid) => `${space}/members/${uid}`;
const grant = (uid, account) => `${member(uid)}/access/${account}`;
const entry = (account, id) => `${space}/accounts/${account}/entries/${id}`;
const invite = (id) => `${space}/invites/${id}`;
const account = (id) => `${space}/accounts/${id}`;
const code = (last) => `00000000-0000-4000-8000-${String(last).padStart(12, '0')}`;

const makeAccount = (name) => ({
  name, currency: 'EGP', decimals: 2, opening: 9000, createdAt: serverTimestamp(),
});
const inviteData = (email, expiresAt = Date.now() + 3600000) => ({
  email, expiresAt: Timestamp.fromMillis(expiresAt),
  createdAt: serverTimestamp(), state: 'open',
});
const createEntry = (id, uid, generation = code(101)) => ({
  title: 'Groceries', minor: -1500, day: '2026-11-25', deleted: false,
  revision: 1, author: uid, updatedBy: uid, mutation: id, generation,
  createdAt: serverTimestamp(), updatedAt: serverTimestamp(),
});
const revise = (revision, uid, mutation, generation = uid === 'owner' ? 'owner' : code(101)) => ({
  minor: -1000, revision, updatedBy: uid, mutation, generation, updatedAt: serverTimestamp(),
});

function joinHousehold(db, uid, email, id, { includeInvite = true } = {}) {
  const batch = writeBatch(db);
  if (includeInvite) batch.update(doc(db, invite(id)), { state: 'accepted', acceptedBy: uid });
  batch.set(doc(db, member(uid)), { email, generation: id, active: true, joinedAt: serverTimestamp() });
  batch.set(doc(db, link(uid)), { linkedAt: serverTimestamp() });
  return batch.commit();
}

before(async () => {
  env = await initializeTestEnvironment({
    projectId,
    firestore: {
      host: '127.0.0.1', port: 8180,
      rules: readFileSync(join(__dirname, 'firestore.rules'), 'utf8'),
    },
  });
  await env.clearFirestore();
});

after(async () => { await env?.cleanup(); });

test('owner creates a private workspace and two accounts', async () => {
  const owner = actor('owner', 'owner@example.com');
  const outsider = actor('outsider', 'outsider@example.com');
  const nobody = env.unauthenticatedContext().firestore();
  const batch = writeBatch(owner);
  batch.set(doc(owner, space), { name: 'Home', owner: 'owner', createdAt: serverTimestamp() });
  batch.set(doc(owner, link('owner')), { linkedAt: serverTimestamp() });
  await assertSucceeds(batch.commit());
  for (const [id, name] of [[account1, 'Groceries'], [account2, 'Rent']]) {
    await assertSucceeds(setDoc(doc(owner, account(id)), makeAccount(name)));
    await assertFails(getDoc(doc(outsider, account(id))));
    await assertFails(getDoc(doc(nobody, account(id))));
  }
  await assertFails(getDocs(collection(outsider, 'households')));
  await assertFails(getDoc(doc(outsider, link('owner'))));
  await assertFails(setDoc(doc(outsider, link('outsider')), { linkedAt: serverTimestamp() }));
  await assertFails(updateDoc(doc(owner, space), { owner: 'outsider' }));
});

test('a verified matching recipient can consume an invite exactly once and must commit membership atomically', async () => {
  const owner = actor('owner', 'owner@example.com');
  const recipient = actor('recipient', 'Person@Example.com');
  const outsider = actor('outsider', 'outsider@example.com');
  const unverified = actor('unverified', 'person@example.com', false);
  const inviteId = code(101);
  await assertSucceeds(setDoc(doc(owner, invite(inviteId)), inviteData('person@example.com')));
  await assertFails(getDoc(doc(outsider, invite(inviteId))));
  await assertFails(joinHousehold(outsider, 'outsider', 'outsider@example.com', inviteId));
  await assertFails(joinHousehold(unverified, 'unverified', 'person@example.com', inviteId));
  await assertFails(joinHousehold(recipient, 'recipient', 'person@example.com', inviteId, { includeInvite: false }));
  await assertFails(updateDoc(doc(recipient, invite(inviteId)), { state: 'accepted', acceptedBy: 'recipient' }));
  await assertSucceeds(joinHousehold(recipient, 'recipient', 'person@example.com', inviteId));
  await assertFails(joinHousehold(actor('same-email', 'person@example.com'),
    'same-email', 'person@example.com', inviteId));
  await assertSucceeds(getDoc(doc(recipient, space)));
  await assertFails(getDoc(doc(recipient, account(account1))));
});

test('grants isolate accounts, viewers cannot post, and stale updates are rejected', async () => {
  const owner = actor('owner', 'owner@example.com');
  const recipient = actor('recipient', 'person@example.com');
  const row = code(201);
  await assertFails(setDoc(doc(recipient, grant('recipient', account1)),
    { role: 'editor', generation: code(101) }));
  await assertSucceeds(setDoc(doc(owner, grant('recipient', account1)),
    { role: 'viewer', generation: code(101) }));
  await assertSucceeds(getDoc(doc(recipient, account(account1))));
  await assertFails(getDoc(doc(recipient, account(account2))));
  await assertFails(getDocs(collection(recipient, `${space}/accounts`)));
  await assertFails(setDoc(doc(recipient, entry(account1, row)), createEntry(row, 'recipient')));
  await assertSucceeds(setDoc(doc(owner, grant('recipient', account1)),
    { role: 'editor', generation: code(101) }));
  await assertFails(setDoc(doc(recipient, entry(account2, row)), createEntry(row, 'recipient')));
  await assertSucceeds(setDoc(doc(recipient, entry(account1, row)), createEntry(row, 'recipient')));
  await assertFails(setDoc(doc(recipient, entry(account1, row)), createEntry(row, 'recipient')));
  await assertSucceeds(updateDoc(doc(owner, entry(account1, row)), revise(2, 'owner', code(202))));
  await assertFails(updateDoc(doc(recipient, entry(account1, row)), revise(2, 'recipient', code(203))));
  await assertFails(updateDoc(doc(recipient, entry(account1, row)), { ...revise(3, 'recipient', code(204)), author: 'outsider' }));
  await assertFails(deleteDoc(doc(recipient, entry(account1, row))));
  await assertSucceeds(updateDoc(doc(recipient, entry(account1, row)),
    { ...revise(3, 'recipient', code(205)), deleted: true }));
  await assertFails(updateDoc(doc(recipient, entry(account1, row)),
    { ...revise(4, 'recipient', code(206)), deleted: false }));
  assert.equal((await getDoc(doc(owner, entry(account1, row)))).data().deleted, true);
});

test('revocation rejects queued writes and a new invitation does not revive old grants', async () => {
  const owner = actor('owner', 'owner@example.com');
  const recipient = actor('recipient', 'person@example.com');
  const row = code(301);
  await assertSucceeds(updateDoc(doc(owner, member('recipient')), { active: false }));
  await assertFails(getDoc(doc(recipient, space)));
  await assertFails(getDoc(doc(recipient, account(account1))));
  await assertFails(setDoc(doc(recipient, entry(account1, row)), createEntry(row, 'recipient')));
  await assertFails(joinHousehold(recipient, 'recipient', 'person@example.com', code(101)));
  await assertSucceeds(setDoc(doc(owner, invite(code(302))), inviteData('person@example.com')));
  await assertSucceeds(joinHousehold(recipient, 'recipient', 'person@example.com', code(302)));
  await assertFails(getDoc(doc(recipient, account(account1))));
  await assertFails(setDoc(doc(owner, grant('recipient', account1)),
    { role: 'editor', generation: code(101) }));
  await assertSucceeds(setDoc(doc(owner, grant('recipient', account1)),
    { role: 'editor', generation: code(302) }));
  await assertSucceeds(getDoc(doc(recipient, account(account1))));
  await assertFails(setDoc(doc(recipient, entry(account1, row)), createEntry(row, 'recipient')));
  await assertSucceeds(setDoc(doc(recipient, entry(account1, row)),
    createEntry(row, 'recipient', code(302))));
});

test('revoked and expired invites cannot be accepted', async () => {
  const owner = actor('owner', 'owner@example.com');
  const late = actor('late', 'late@example.com');
  const revoked = actor('revoked', 'revoked@example.com');
  await assertSucceeds(setDoc(doc(owner, invite(code(402))), inviteData('revoked@example.com')));
  await assertSucceeds(updateDoc(doc(owner, invite(code(402))), { state: 'revoked' }));
  await assertFails(joinHousehold(revoked, 'revoked', 'revoked@example.com', code(402)));
  await env.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), invite(code(401))),
      inviteData('late@example.com', Date.now() - 60_000));
  });
  await assertFails(joinHousehold(late, 'late', 'late@example.com', code(401)));
});
