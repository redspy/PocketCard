import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  server: {
    // Godot 임시 파일·빌드 결과·서버 저장 파일은 감시하지 않는다 (Godot 이 파일을 잡고 있으면 감시기가 죽음)
    watch: { ignored: ['**/godot/.godot/**', '**/godot/cards/**', '**/build/**', '**/.data/**', '**/.cache/**', '**/dist/**'] },
  },
});
