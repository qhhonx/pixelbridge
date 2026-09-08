import 'server-only';

const repositoryURL = process.env.NEXT_PUBLIC_REPOSITORY_URL || 'https://github.com/qhhonx/pixelbridge';
const parsed = new URL(repositoryURL);
if (parsed.origin !== 'https://github.com' || !/^\/[\w.-]+\/[\w.-]+\/?$/.test(parsed.pathname)) {
  throw new Error('Repository must be a GitHub owner/repository URL');
}
const slug = parsed.pathname.replace(/^\/|\/$/g, '');
export const releasesURL = `https://github.com/${slug}/releases`;
type Asset = { name: string; browser_download_url: string; size: number };
type Release = { draft: boolean; tag_name: string; published_at: string | null; assets: Asset[] };
function versionParts(tag: string) {
  const match = /^v(\d+)\.(\d+)\.(\d+)(?:-beta\.(\d+))?$/.exec(tag);
  return match ? [Number(match[1]), Number(match[2]), Number(match[3]), match[4] ? Number(match[4]) : Number.MAX_SAFE_INTEGER] : [0,0,0,0];
}
export function completeRelease(releases: Release[]) {
  for (const release of [...releases].sort((a,b) => {
    const x=versionParts(a.tag_name), y=versionParts(b.tag_name);
    for (let i=0; i<x.length; i++) { if (x[i] !== y[i]) return y[i]-x[i]; }
    return 0;
  })) {
    if (release.draft || !release.published_at || !/^v\d+\.\d+\.\d+(?:-beta\.\d+)?$/.test(release.tag_name)) continue;
    const expected = `PixelBridge-${release.tag_name.slice(1)}-arm64.zip`;
    const asset = (name: string) => release.assets.find(a => a.name === name && a.size > 0 &&
      a.browser_download_url.startsWith(`https://github.com/${slug}/releases/download/${release.tag_name}/`));
    const archive = asset(expected), appcast = asset('appcast.xml'), hashes = asset('SHA256SUMS');
    if (archive && appcast && hashes) return { archive, appcast, tag: release.tag_name };
  }
  return null;
}
export async function latestRelease() {
  const response = await fetch(`https://api.github.com/repos/${slug}/releases?per_page=30`, {
    headers: { Accept: 'application/vnd.github+json' }, next: { revalidate: 300 }, signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) throw new Error('Release service unavailable');
  const data: unknown = await response.json();
  if (!Array.isArray(data)) throw new Error('Invalid release response');
  return completeRelease(data);
}
