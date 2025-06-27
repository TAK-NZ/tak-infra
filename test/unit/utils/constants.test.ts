/**
 * Test suite for constants
 */
import { DATABASE_CONSTANTS, TAK_SERVER_PORTS, EFS_CONSTANTS } from '../../../lib/utils/constants';

describe('Constants', () => {
  test('should have valid database constants', () => {
    expect(DATABASE_CONSTANTS.USERNAME).toBe('tak');
    expect(DATABASE_CONSTANTS.DEFAULT_DATABASE_NAME).toBe('takserver');
    expect(DATABASE_CONSTANTS.PORT).toBe(5432);
    expect(DATABASE_CONSTANTS.PASSWORD_LENGTH).toBeGreaterThan(0);
  });

  test('should have valid TAK server ports', () => {
    expect(TAK_SERVER_PORTS.HTTP).toBe(80);
    expect(TAK_SERVER_PORTS.HTTPS).toBe(443);
    expect(TAK_SERVER_PORTS.COT_TCP).toBe(8089);
    expect(TAK_SERVER_PORTS.API_ADMIN).toBe(8443);
    expect(TAK_SERVER_PORTS.WEBTAK_ADMIN).toBe(8446);
    expect(TAK_SERVER_PORTS.FEDERATION).toBe(9001);
  });

  test('should have valid EFS constants', () => {
    expect(EFS_CONSTANTS.PORT).toBe(2049);
  });
});