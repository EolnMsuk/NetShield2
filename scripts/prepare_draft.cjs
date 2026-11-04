// No publication. Every mutation is guarded against a stale branch or a draft
// published by a human. Upload and verify revision-specific staging assets before
// touching the old final names. A failure leaves an explicitly incomplete draft.
const fs = require('node:fs');
const crypto = require('node:crypto');
class AssetMismatch extends Error {}
const hash = data => crypto.createHash('sha256').update(data).digest('hex');

async function prepareDraft({github, context, core, directory = 'release-assets', version, packageId, changelog}) {
  const repository = {owner: context.repo.owner, repo: context.repo.repo};
  const names = ['rootful', 'rootless', 'roothide'].map(variant => `${packageId}_${version}_${variant}.deb`);
  const expected = [...names, ...names.map(name => `${name}.manifest.json`)].sort();
  const found = fs.readdirSync(directory).sort();
  if (JSON.stringify(found) !== JSON.stringify(expected)) throw new Error('Expected three debs and three provenance manifests');
  const assets = names.map(name => {
    if (!fs.lstatSync(`${directory}/${name}`).isFile() || fs.lstatSync(`${directory}/${name}`).isSymbolicLink()) throw new Error('Not a regular deb');
    const data = fs.readFileSync(`${directory}/${name}`);
    const manifestPath = `${directory}/${name}.manifest.json`;
    if (!fs.lstatSync(manifestPath).isFile()) throw new Error('Expected a regular CI manifest');
    const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
    if (manifest.schema !== 1 || manifest.source !== context.sha || manifest.package !== name || manifest.version !== version ||
        manifest.scheme !== name.slice(0, -4).split('_').at(-1) || manifest.sha256 !== hash(data) || manifest.size !== data.length || !data.length ||
        !/^[0-9a-f]{40}$/.test(manifest.theos) || !/^[0-9a-f]{64}$/.test(manifest.sdk_sha256) || !manifest.tools?.python)
      throw new Error(`Package/provenance mismatch: ${name}`);
    return {name, data};
  });
  const source = context.sha;
  if (!/^[0-9a-f]{40}$/.test(source)) throw new Error('Expected a complete source revision');
  const stagedName = name => name.replace(/\.deb$/, `.${source}.staged.deb`);
  const releases = await github.paginate(github.rest.repos.listReleases, {...repository, per_page: 100});
  let release = releases.find(candidate => candidate.tag_name === version);
  if (release && !release.draft) { core.info(`Keeping published release unchanged: ${release.html_url}`); return; }
  async function guard() {
    const {data: branch} = await github.rest.repos.getBranch({...repository, branch: 'main'});
    if (branch.commit.sha !== source) throw new Error('Stale build: main has moved; draft preparation stopped');
    if (release) {
      const {data: current} = await github.rest.repos.getRelease({...repository, release_id: release.id});
      if (!current.draft) throw new Error('Release was published during preparation; no further mutation allowed');
      if (current.tag_name !== version) throw new Error('Draft version changed during preparation');
    }
  }
  await guard();
  const metadata = {...repository, tag_name: version, target_commitish: source, name: `NetShield2 v${version}`,
    body: `INCOMPLETE BUILD ${source}\nDo not publish. Asset verification/promotion is pending.`, draft: true, prerelease: false};
  if (release) ({data: release} = await github.rest.repos.updateRelease({...metadata, release_id: release.id}));
  else ({data: release} = await github.rest.repos.createRelease(metadata));
  const list = () => github.paginate(github.rest.repos.listReleaseAssets, {...repository, release_id: release.id, per_page: 100});
  async function verify(remote, asset) {
    if (!remote) throw new Error(`Missing uploaded asset: ${asset.name}`);
    if (remote.size !== asset.data.length) throw new AssetMismatch(`Uploaded size mismatch: ${asset.name}`);
    const response = await github.rest.repos.getReleaseAsset({...repository, asset_id: remote.id, headers: {accept: 'application/octet-stream'}});
    const bytes = Buffer.from(response.data);
    if (hash(bytes) !== hash(asset.data)) throw new AssetMismatch(`Uploaded content mismatch: ${asset.name}`);
  }
  for (const asset of assets) {
    const staged = stagedName(asset.name);
    const existing = (await list()).find(candidate => candidate.name === staged);
    if (existing) {
      try {
        await verify(existing, asset);
        continue;
      } catch (error) {
        if (!(error instanceof AssetMismatch)) throw error;
        await guard();
        await github.rest.repos.deleteReleaseAsset({...repository, asset_id: existing.id});
      }
    }
    await guard();
    const {data: remote} = await github.rest.repos.uploadReleaseAsset({...repository, release_id: release.id, name: staged,
      data: asset.data, headers: {'content-type': 'application/octet-stream', 'content-length': asset.data.length}});
    await verify(remote, asset);
  }
  for (const asset of assets) {
    const remote = await list();
    const staged = remote.find(candidate => candidate.name === stagedName(asset.name));
    await verify(staged, asset);
    const previous = remote.find(candidate => candidate.name === asset.name);
    if (previous) { await guard(); await github.rest.repos.deleteReleaseAsset({...repository, asset_id: previous.id}); }
    await guard();
    await github.rest.repos.updateReleaseAsset({...repository, asset_id: staged.id, name: asset.name});
  }
  // Verify the promoted debs before cleaning extras from this version's draft.
  const promoted = await list();
  for (const asset of assets) await verify(promoted.find(candidate => candidate.name === asset.name), asset);
  for (const remote of promoted) {
    if (!names.includes(remote.name)) {
      await guard();
      await github.rest.repos.deleteReleaseAsset({...repository, asset_id: remote.id});
    }
  }
  const final = await list();
  if (final.length !== names.length || new Set(final.map(asset => asset.name)).size !== names.length) throw new Error('Incomplete final asset set');
  for (const asset of assets) await verify(final.find(candidate => candidate.name === asset.name), asset);
  await guard();
  await github.rest.repos.updateRelease({...repository, release_id: release.id, body: changelog});
  core.info(`Verified draft for ${source}: ${release.html_url}`);
}
module.exports = {prepareDraft};
