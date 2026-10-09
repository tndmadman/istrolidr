// Native protocol example: operator-defined authorization for a test server.
// Actual Istrolid client sends positional command arrays, not JSON lab-v1 objects.
export function onCommand({command}) {
  if (command.name === 'moveOrder') {
    return { reject: true, reason: 'Blocked native movement command for policy testing' };
  }
  return { tags: ['native-policy'] };
}
