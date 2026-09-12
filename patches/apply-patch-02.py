#!/usr/bin/env python3
"""Apply session persistence patch: link -> rename fallback for Android EACCES."""
import sys, re

TARGET = sys.argv[1] if len(sys.argv) > 1 else "lib/index.js"

with open(TARGET, 'r') as f:
    content = f.read()

# 1) Add rename to import
content = content.replace(
    'import { link, lstat, mkdir, mkdtemp, open, readFile, readdir, realpath, rm, stat, truncate } from "node:fs/promises";',
    'import { link, lstat, mkdir, mkdtemp, open, readFile, readdir, realpath, rm, rename, stat, truncate } from "node:fs/promises";'
)

# 2) Add catch block after link call
old = '''			await link(tmp, finalPath);
			linked = true;
		} finally {'''
new = '''			await link(tmp, finalPath);
			linked = true;
		} catch (error) {
			/* Android sepolicy blocks link(2) (EACCES/EPERM); fall back to same-filesystem atomic rename */
			if (error?.code === "EACCES" || error?.code === "EPERM") await rename(tmp, finalPath);
			else throw error;
		} finally {'''

if old not in content:
    print("WARNING: link pattern not found, patch may not apply", file=sys.stderr)
    sys.exit(1)

content = content.replace(old, new)

with open(TARGET, 'w') as f:
    f.write(content)

print("OK: session persistence patch applied")
