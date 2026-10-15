#include <stdint.h>
#include "AudioCore.h"
typedef struct LC LC;
LC *lc_create(void);
int32_t lc_start(LC *, uint32_t device, uint32_t channels, uint64_t origin);
int32_t lc_start_output(LC *, uint32_t device, uint64_t origin);
void lc_stop(LC *);
void lc_destroy(LC *);
uint64_t lc_now(void);
double lc_bin_rms(LC *, uint32_t bin);
uint32_t lc_bin_count(LC *, uint32_t bin);
int32_t lc_error(LC *);
