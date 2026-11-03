const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const {prepareDraft} = require('./prepare_draft.cjs');

function mock() {
  const state = {source: 'a'.repeat(40), assets: [], release: null, writes: 0, uploads: 0, promotions: 0, guards: 0};
  const repos = {
    listReleases: async () => state.release ? [state.release] : [],
    getBranch: async () => { state.guards++; return {data: {commit: {sha: state.moveAt && state.guards >= state.moveAt ? 'b'.repeat(40) : state.source}}}; },
    getRelease: async () => ({data: state.release}),
    createRelease: async data => { state.writes++; state.release = {...data, id: 1, html_url: 'https://example.test/draft'}; return {data: state.release}; },
    updateRelease: async data => { state.writes++; Object.assign(state.release, data); return {data: state.release}; },
    listReleaseAssets: async () => state.assets,
    uploadReleaseAsset: async data => {
      if (++state.uploads === state.failUpload) throw new Error('Injected upload failure');
      state.writes++;
      const asset = {id: state.uploads, name: data.name, size: data.data.length, bytes: Buffer.from(data.data)};
      state.assets.push(asset); return {data: asset};
    },
    getReleaseAsset: async ({asset_id}) => ({data: state.corrupt ? Buffer.from('corrupt') : state.assets.find(a => a.id === asset_id).bytes}),
    deleteReleaseAsset: async ({asset_id}) => { state.writes++; state.assets = state.assets.filter(a => a.id !== asset_id); },
    updateReleaseAsset: async ({asset_id, name}) => {
      if (++state.promotions === state.failPromotion) throw new Error('Injected promotion failure');
      state.writes++; const asset = state.assets.find(a => a.id === asset_id); asset.name = name; return {data: asset};
    }
  };
  return {state, github: {rest: {repos}, paginate: async (method, args) => method(args)}};
}
async function run() {
  const temporaryRoot = path.resolve(__dirname, '../.validation-tmp');
  fs.mkdirSync(temporaryRoot, {recursive: true});
  const directory = fs.mkdtempSync(path.join(temporaryRoot, 'draft-'));
  assert(directory.startsWith(temporaryRoot + path.sep));
  const version = '2.6.4', packageId = 'com.eolnmsuk.netshield';
  try {
    for (const scheme of ['rootful', 'rootless', 'roothide']) {
      const name = `${packageId}_${version}_${scheme}.deb`, data = Buffer.from(`fixture ${scheme}`);
      fs.writeFileSync(path.join(directory, name), data);
      fs.writeFileSync(path.join(directory, name + '.manifest.json'), JSON.stringify({schema: 1, source: 'a'.repeat(40),
        package: name, version, scheme, size: data.length, sha256: crypto.createHash('sha256').update(data).digest('hex')}));
    }
    const input = instance => ({github: instance.github, context: {repo: {owner: 'test', repo: 'test'}, sha: 'a'.repeat(40)},
      core: {info: () => {}}, directory, version, packageId, changelog: 'Test changelog'});
    let instance = mock();
    await prepareDraft(input(instance));
    assert.equal(instance.state.assets.length, 4);
    assert(!instance.state.release.body.includes('INCOMPLETE'));
    assert(instance.state.release.draft);
    assert(instance.state.release.body.includes('Publication remains manual'));
    instance = mock(); instance.state.source = 'b'.repeat(40);
    await assert.rejects(prepareDraft(input(instance)), /Stale build/);
    assert.equal(instance.state.writes, 0);
    for (const fault of ['failUpload', 'failPromotion']) {
      instance = mock(); instance.state[fault] = 2;
      await assert.rejects(prepareDraft(input(instance)), /Injected/);
      assert(instance.state.release.body.includes('INCOMPLETE'));
      instance.state[fault] = null;
      await prepareDraft(input(instance));
      assert.equal(instance.state.assets.length, 4);
      assert(!instance.state.release.body.includes('INCOMPLETE'));
      assert(!instance.state.assets.some(asset => asset.name.includes('.staged')));
    }
    instance = mock(); instance.state.release = {id: 1, tag_name: version, draft: false};
    await prepareDraft(input(instance)); assert.equal(instance.state.writes, 0);
    instance = mock(); instance.state.moveAt = 3;
    await assert.rejects(prepareDraft(input(instance)), /Stale build/);
    assert(instance.state.release.body.includes('INCOMPLETE'));
    instance = mock(); instance.state.corrupt = true;
    await assert.rejects(prepareDraft(input(instance)), /content mismatch/);
    assert(instance.state.release.body.includes('INCOMPLETE'));
    const manifestPath = path.join(directory, `${packageId}_${version}_rootful.deb.manifest.json`);
    const manifest = JSON.parse(fs.readFileSync(manifestPath)); manifest.source = 'c'.repeat(40);
    fs.writeFileSync(manifestPath, JSON.stringify(manifest));
    instance = mock();
    await assert.rejects(prepareDraft(input(instance)), /provenance mismatch/);
    assert.equal(instance.state.writes, 0);
    return 'Passed draft preparation, stale revision, published release, corruption and partial upload/promotion retry fixtures';
  } finally {
    assert(path.resolve(directory).startsWith(temporaryRoot + path.sep));
    fs.rmSync(directory, {recursive: true, force: true});
  }
}
module.exports = {run};
if (require.main === module) run().then(console.log).catch(error => { console.error(error); process.exitCode = 1; });
