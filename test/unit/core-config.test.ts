import { execSync } from 'child_process';
import * as path from 'path';

describe('CoreConfig Script Tests', () => {
  const testScriptPath = path.join(__dirname, '../CoreConfig/test-createCoreConfig.sh');
  
  test('CoreConfig generation and validation', () => {
    expect(() => {
      execSync(`bash ${testScriptPath}`, {
        stdio: 'inherit',
        cwd: path.dirname(testScriptPath)
      });
    }).not.toThrow();
  }, 30000); // 30 second timeout for comprehensive tests
});