import tseslint from 'typescript-eslint';

export default tseslint.config(
  { ignores: ['design/**', '**/node_modules/**', '**/.data/**', 'apps/ios/**'] },
  ...tseslint.configs.recommended,
);
