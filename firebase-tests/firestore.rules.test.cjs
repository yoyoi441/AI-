const { after, before, beforeEach, test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} = require("@firebase/rules-unit-testing");
const {
  Timestamp,
  collection,
  doc,
  getDoc,
  getDocs,
  setDoc,
  writeBatch,
} = require("firebase/firestore");

const projectId = "demo-token-mihariban";
const groupId = "ABCDEFGHJKLMNPQR";
let testEnv;

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId,
    firestore: {
      rules: fs.readFileSync(path.join(__dirname, "..", "firestore.rules"), "utf8"),
    },
  });
});

beforeEach(async () => {
  await testEnv.clearFirestore();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, "syncGroups", groupId), {
      ownerUid: "owner",
      createdAt: Timestamp.now(),
      schemaVersion: 2,
    });
    await setDoc(doc(db, "syncGroups", groupId, "members", "owner"), {
      deviceId: "owner-device-0001",
      platform: "macos",
      joinedAt: Timestamp.now(),
    });
  });
});

after(async () => {
  await testEnv.cleanup();
});

test("未認証と非参加ユーザーは同期データを読めない", async () => {
  const unauthenticated = testEnv.unauthenticatedContext().firestore();
  const stranger = testEnv.authenticatedContext("stranger").firestore();
  await assertFails(getDoc(doc(unauthenticated, "syncGroups", groupId)));
  await assertFails(getDocs(collection(stranger, "syncGroups", groupId, "claudeEvents")));
  await assertFails(getDocs(collection(stranger, "syncGroups")));
});

test("16文字コードを知る認証済み端末だけがメンバー参加できる", async () => {
  const member = testEnv.authenticatedContext("member").firestore();
  await assertSucceeds(setDoc(doc(member, "syncGroups", groupId, "members", "member"), {
    deviceId: "member-device-0001",
    platform: "windows",
    joinedAt: Timestamp.now(),
  }));
  await assertSucceeds(getDoc(doc(member, "syncGroups", groupId)));

  const missingGroup = "ZZZZZZZZZZZZZZZZ";
  await assertFails(setDoc(doc(member, "syncGroups", missingGroup, "members", "member"), {
    deviceId: "member-device-0001",
    platform: "windows",
    joinedAt: Timestamp.now(),
  }));
});

test("新規グループと作成端末メンバーを同じバッチで作成できる", async () => {
  const creator = testEnv.authenticatedContext("creator").firestore();
  const newGroup = "23456789ABCDEFGH";
  const batch = writeBatch(creator);
  batch.set(doc(creator, "syncGroups", newGroup), {
    ownerUid: "creator",
    createdAt: Timestamp.now(),
    schemaVersion: 2,
  });
  batch.set(doc(creator, "syncGroups", newGroup, "members", "creator"), {
    deviceId: "creator-device-01",
    platform: "macos",
    joinedAt: Timestamp.now(),
  });
  await assertSucceeds(batch.commit());
});

test("参加端末は自端末IDの妥当なイベントだけを書ける", async () => {
  const owner = testEnv.authenticatedContext("owner").firestore();
  const eventPath = doc(owner, "syncGroups", groupId, "claudeEvents", "event-1");
  const validEvent = {
    deviceId: "owner-device-0001",
    event: {
      timestamp: Timestamp.now(),
      model: "claude-sonnet",
      inputTokens: 100,
      outputTokens: 50,
      cacheCreationTokens: 0,
      cacheReadTokens: 0,
      sessionId: "session-1",
      projectPath: "/project",
    },
  };
  await assertSucceeds(setDoc(eventPath, validEvent));
  await assertFails(setDoc(doc(owner, "syncGroups", groupId, "claudeEvents", "spoofed"), {
    ...validEvent,
    deviceId: "another-device",
  }));
  await assertFails(setDoc(doc(owner, "syncGroups", groupId, "claudeEvents", "too-old"), {
    ...validEvent,
    event: {
      ...validEvent.event,
      timestamp: Timestamp.fromMillis(Date.now() - 11 * 24 * 60 * 60 * 1000),
    },
  }));
});

test("参加端末は本文を含まない妥当なOllama使用量だけを書ける", async () => {
  const owner = testEnv.authenticatedContext("owner").firestore();
  const validEvent = {
    deviceId: "owner-device-0001",
    event: {
      timestamp: Timestamp.now(),
      model: "gpt-oss:20b",
      inputTokens: 120,
      outputTokens: 45,
      totalDurationNanoseconds: 123456789,
      source: "local",
      requestId: "ollama-request-1",
    },
  };
  await assertSucceeds(setDoc(doc(owner, "syncGroups", groupId, "ollamaEvents", "event-1"), validEvent));
  await assertFails(setDoc(doc(owner, "syncGroups", groupId, "ollamaEvents", "with-prompt"), {
    ...validEvent,
    event: { ...validEvent.event, prompt: "同期してはいけない本文" },
  }));
  await assertFails(setDoc(doc(owner, "syncGroups", groupId, "ollamaEvents", "invalid-source"), {
    ...validEvent,
    event: { ...validEvent.event, source: "other" },
  }));
});

test("端末は自分のメンバー登録を削除して同期解除できる", async () => {
  const owner = testEnv.authenticatedContext("owner").firestore();
  const memberRef = doc(owner, "syncGroups", groupId, "members", "owner");
  const { deleteDoc } = require("firebase/firestore");
  await assertSucceeds(deleteDoc(memberRef));
  await assertFails(getDoc(doc(owner, "syncGroups", groupId)));
  assert.ok(true);
});
