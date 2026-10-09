// EXAMPLE trusted server-side test plugin; enabled by --plugin deny-unit-13.mjs.
// This does not execute arbitrary code from remote clients.
export function onCommand({ command, session }) {
  if (command.name === 'fire' && command.args.unitId === 13) {
    return { reject: true, reason: 'Blocked test unit 13 by security policy' };
  }
  return { tags: ['sample-policy', session.role] };
}
