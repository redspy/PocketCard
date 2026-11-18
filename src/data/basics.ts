// 기본 포켓몬(멀리건 판정용). 한글 이미지의 "기본" 표기로 확인한 코드.
export const BASIC_POKEMON = new Set<string>([
  // 드래펄트 ex (코리안리그 S1)
  'SV8a_118', 'SV8a_064', 'SV8a_001', 'SV8a_075', 'SV8a_084', 'SV8a_225', 'SV7a_078', 'SV6a_089',
  // 가디안 ex (코리안리그 S3)
  'M1S_040', 'SV6_055', 'SV11W_041', 'SV4K_032', 'MBD_005', 'SV2a_151', 'SV9_033', 'SV6a_038',
  // 부스터 ex / 리자몽 ex / 타부자고 ex / 파쪼옥
  'SV7_076', 'SV8a_131', 'SV8a_125', 'SV2a_133', 'SV8a_224', 'SV6_127', 'SV7_130', 'SV8a_226', 'SV4a_327',
  'SV2a_195', 'M2_011', 'SV2a_168', 'SV3_118', 'SV6a_068', 'SV4a_087', 'SV7a_024', 'M1L_027', 'M1L_026',
  'SV8a_104', 'SV11B_069', 'SV7_032', 'SV1V_037', 'SV1V_094', 'SV4M_027', 'SV4M_079', 'SV8_033', 'SV8_122',
  'SV5a_084', 'SV5M_084', 'M1L_080', 'SV6a_040', 'MC_312',
  // 참고용 덱
  'SV6_079', 'SV5K_056', 'M3_061', 'M1S_051', 'SV9a_007',
  // 레귤레이션 교체로 추가
  'SV7a_019', 'M2a_227', 'SV5a_052',
]);
export const isBasicPokemon = (key: string) => BASIC_POKEMON.has(key);
