import { FsError } from '@deepseek-ai/dsh-fs';
import { join } from 'node:path';
import { GuestPaths } from './paths.mjs';

const alias = path => path === '/workspace' || path.startsWith('/workspace/') || path === '/tmp' || path.startsWith('/tmp/');
const profileAlias = path => path === '/dsh-profiles' || path.startsWith('/dsh-profiles/');

// The iOS file tools supply the immutable session root. Ordinary provider
// calls and remote filesystems keep their existing path contract.
export function guestFilePath(path, options, subprocess, { followFinalLink = true } = {}, temporaryRoot) {
  if (!options || !Object.hasOwn(options, 'iosGuestWorkspaceRoot')) return path;
  // 只读别名 /dsh-profiles → $DSH_HOME/profiles（host 路径）：文件工具
  // 直接读 profile/log，不经 guest 工作区挂载；.. 穿越拒绝。
  if (profileAlias(path)) {
    const home = process.env.DSH_HOME;
    if (!home) return path;
    const suffix = path.slice('/dsh-profiles'.length);
    if (suffix.split('/').includes('..')) throw new FsError('EACCES: /dsh-profiles 不接受父级穿越', 'FS_SANDBOX_DENIED');
    return join(home, 'profiles', suffix);
  }
  if (!alias(path)) return path;
  try {
    const paths = new GuestPaths({
      workspaceRoot: options.iosGuestWorkspaceRoot,
      temporaryRoot,
      forbiddenRoots: [process.env.DSH_HOME, process.env.DSH_AGENTS_HOME].filter(Boolean),
    });
    // Host paths may themselves live below /tmp in a validation environment.
    // Recognize configured host roots before interpreting the guest spelling.
    if (subprocess?.isHostPath(path)) return path;
    return paths.toHost(path, { followFinalLink });
  } catch (error) {
    if (error.code !== 'EACCES') throw error;
    throw new FsError(error.message, 'FS_SANDBOX_DENIED', { cause: error });
  }
}
