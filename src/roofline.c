#include "roofline.h"
#include "MSC/MSC.h"
#ifdef USE_OMP
#include <omp.h>
#endif

hwloc_topology_t topology = NULL;            /* Current machine topology  */
size_t           alignement = 0;             /* Level 1 cache line size */
size_t           LLC_size = 0;               /* Last Level Cache size */
float            cpu_freq = 0;               /* In Hz */
char *           compiler = NULL;              /* The compiler name to compile the roofline validation. */
struct roofline_progress_bar progress_bar;   /* Global progress bar of the benchmark */

int roofline_lib_init(void)
{
    /* Initialize topology */
    if(hwloc_topology_init(&topology) ==-1){
	fprintf(stderr, "hwloc_topology_init failed.\n");
	return -1;
    }
    hwloc_topology_set_icache_types_filter(topology, HWLOC_TYPE_FILTER_KEEP_ALL);
    if(hwloc_topology_load(topology) ==-1){
	fprintf(stderr, "hwloc_topology_load failed.\n");
	return -1;
    }

    /* Bind to PU:0 */
    roofline_hwloc_cpubind(hwloc_get_obj_by_type(topology,HWLOC_OBJ_PU,0)->cpuset);

    /* get first cache linesize */
    hwloc_obj_t L1 = roofline_hwloc_get_next_memory(NULL);
    if(L1==NULL){
	errEXIT("No cache found.");
    }
    if(!roofline_hwloc_objtype_is_cache(L1->type) || 
       (L1->attr->cache.type != HWLOC_OBJ_CACHE_UNIFIED && 
	L1->attr->cache.type != HWLOC_OBJ_CACHE_DATA)){
	errEXIT("First memory obj is not a data cache.");
    }

    /* Set alignement */
    alignement = L1->attr->cache.linesize;

    /* Find LLC cache size */
    hwloc_obj_t LLC = hwloc_get_root_obj(topology);
    while(LLC != NULL && !roofline_hwloc_objtype_is_cache(LLC->type))
	LLC = LLC->first_child;
    if(LLC == NULL)
	errEXIT("Error: no LLC cache found\n");
    LLC_size = ((struct hwloc_cache_attr_s *)LLC->attr)->size*4;

    /* Check if cpu frequency has been defined */
#ifndef BENCHMARK_CPU_FREQ
    char * cpu_freq_str = getenv("BENCHMARK_CPU_FREQ");
    if(cpu_freq_str == NULL)
	errEXIT("Please define the machine cpu frequency (in Hertz) with build option BENCHMARK_CPU_FREQ or the environement variable of the same name");
    cpu_freq = atof(cpu_freq_str);
#else 
    cpu_freq = BENCHMARK_CPU_FREQ
#endif 

    /* set compiler */
#ifdef CC
    compiler = roofline_macro_xstr(CC);
#else
    compiler = getenv("CC");
    if(compiler==NULL){
	errEXIT("Undefined compiler. Please set env CC to your compiler.");
    }
#endif
    return 0;
}

inline void roofline_lib_finalize(void)
{
    hwloc_topology_destroy(topology);
}

struct roofline_sample_out  
roofline_output_accumulate(struct roofline_sample_out a, struct roofline_sample_out b){
    struct roofline_sample_out ret = {0,0,0,0,0};
    uint64_t cyc_a = a.ts_end-a.ts_start;
    uint64_t cyc_b = b.ts_end-b.ts_start;
    ret.ts_end = roofline_MAX(cyc_a, cyc_b);
    ret.flops = a.flops + b.flops;
    ret.bytes = a.bytes + b.bytes;
    ret.instructions = a.instructions + b.instructions;
    return ret;
}

inline void print_roofline_sample_output(struct roofline_sample_out * out){
    printf("%20lu %20lu %20lld %20lld %20lld\n", 
	   out->ts_start, out->ts_end, out->instructions, out->bytes, out->flops);
}

void roofline_fpeak(FILE * output)
{
    struct roofline_sample_out result = {0,0,0,0,0};
    struct roofline_sample_in in = {1,NULL,0};  
    double sd = 0;

#ifdef USE_OMP
    omp_set_num_threads(hwloc_get_nbobjs_by_type(topology, HWLOC_OBJ_CORE));
    hwloc_obj_t obj = hwloc_get_root_obj(topology);    
#else
    hwloc_obj_t obj = hwloc_get_obj_by_type(topology, HWLOC_OBJ_PU, 0);    
#endif

    /* Benchmark */
    roofline_autoset_loop_repeat(fpeak_bench, &in, BENCHMARK_MIN_DUR);
    sd = roofline_repeat_bench(fpeak_bench,&in,&result, roofline_output_median);    
    /* Output */
    const char * info = "FLOPS";
    roofline_print_sample(output, obj, &result, sd, info);
}

static void roofline_memory(FILE * output, hwloc_obj_t memory, double oi, int type){
    roofline_mkstr_stack(progress_info,128);
    roofline_mkstr_stack(info,128);
    void (* bench) (struct roofline_sample_in * in, struct roofline_sample_out * out);    
    if(type==ROOFLINE_LOAD)  snprintf(info, sizeof(info),"%5s", "LOAD");
    if(type==ROOFLINE_STORE) snprintf(info, sizeof(info),"%5s", "STORE");
    bench = roofline_oi_bench(oi,type);

    int nc = hwloc_obj_type_snprintf(progress_info,sizeof(progress_info),memory, 0);
    nc += snprintf(progress_info+nc, sizeof(progress_info)-nc, ":%d %s", memory->logical_index, info);

    /* bind */
    roofline_hwloc_membind(memory);

    /* Get lower memory size as a start or the minimum size if memory is the deepest one */
    size_t lower_bound_size = 4*roofline_hwloc_get_memory_size(roofline_hwloc_get_previous_memory(memory));
    size_t upper_bound_size = roofline_hwloc_get_memory_size(memory);
    lower_bound_size  = roofline_MAX(1024,lower_bound_size);

    upper_bound_size  = roofline_MIN(upper_bound_size,LLC_size*32);
    if(lower_bound_size > upper_bound_size)
	return;

    /* Set the number of running threads to the number of Cores sharing the memory */
#ifdef USE_OMP
    omp_set_num_threads(hwloc_get_nbobjs_inside_cpuset_by_type(topology,memory->cpuset, HWLOC_OBJ_CORE));
#endif
 
    /* get array of input sizes */
    int n_sizes  = ROOFLINE_N_SAMPLES;
    size_t * sizes = roofline_log_array(lower_bound_size, upper_bound_size, &n_sizes);
 
    /* Initialize array of results [{sequential,parallel}, {n_sample}, {pointer}]*/
    struct roofline_sample_out * results = NULL; 
    roofline_alloc(results,sizeof(*results)*n_sizes);

    /*Initialize sample input */
    struct roofline_sample_in in = {1, NULL, sizes[0]};
    alloc_chunk_aligned(&in.stream, upper_bound_size);

    /* Iterate roofline among sizes */
    int i;
    for(i=0;i<n_sizes;i++){
    /*Inform user of the progress */
    roofline_progress_set(&progress_bar, progress_info, 0, i, n_sizes);

    /* Prepare input / output */
    in.stream_size = alloc_chunk_aligned(NULL,sizes[i]);
    roofline_autoset_loop_repeat(bench, &in, BENCHMARK_MIN_DUR);
    struct roofline_sample_out result = {0,0,0,0,0};

    /* benchmark */
    roofline_repeat_bench(bench,&in,&result, roofline_output_median);
    results[i] = result;
    }
    
    /* sort results */
    int median = roofline_output_median(results, n_sizes);
    double sd = roofline_output_sd(results, n_sizes);
    struct roofline_sample_out out = results[median];
    /*Inform user of the progress */
    roofline_progress_set(&progress_bar, progress_info, 0, i, n_sizes);
	
    /* End progress bar */
    roofline_progress_clean();
	
    /* print output */
    roofline_print_sample(output, memory, &out, sd, info);

    /* Cleanup */
    free(results);
    free(in.stream);
}

inline void roofline_bandwidth(FILE * output, hwloc_obj_t mem, int type){
    roofline_memory(output,mem,0,type);
}

inline void roofline_oi(FILE * output, hwloc_obj_t mem, int type, double oi){
    roofline_memory(output,mem,oi,type);
}
