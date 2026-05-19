import { existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const venvPython = process.platform === 'win32' ? '.venv/Scripts/python.exe' : '.venv/bin/python';
const command = existsSync(venvPython) ? venvPython : process.platform === 'win32' ? 'py' : 'python3';
const args = existsSync(venvPython)
  ? ['scripts/test_compact_proxy.py']
  : process.platform === 'win32'
    ? ['-3', 'scripts/test_compact_proxy.py']
    : ['scripts/test_compact_proxy.py'];

const result = spawnSync(command, args, { stdio: 'inherit', shell: false });
if (result.error) {
  console.error(result.error.message);
  process.exit(1);
}
process.exit(result.status ?? 1);
