#include <math.h>
#include "roofline.h"

/* options */
char * output = NULL;
int validate = 0;
hwloc_obj_t mem = NULL;
int load = 0, store = 0;

void usage(char * argv0){
    printf("%s -h  -v -l -s -m <hwloc_ibj:idx> -o <output>\n", argv0);
    printf("%s --help --validate --load --store --memory <hwloc_obj:idx> --output <output>\n", argv0);
    exit(EXIT_SUCCESS);
}

void parse_args(int argc, char ** argv){
    int i = 0;
    while(++i < argc){
	if(!strcmp(argv[i],"--help") || !strcmp(argv[i],"-h"))
	    usage(argv[0]);
	else if(!strcmp(argv[i],"--validate") || !strcmp(argv[i],"-v"))
	    validate = 1;
	else if(!strcmp(argv[i],"--load") || !strcmp(argv[i],"-l"))
	    load = 1;
	else if(!strcmp(argv[i],"--store") || !strcmp(argv[i],"-s"))
	    store = 1;
	else if(!strcmp(argv[i],"--memory") || !strcmp(argv[i],"-m")){
	    mem = roofline_hwloc_parse_obj(argv[++i]);
	}
	else if(!strcmp(argv[i],"--output") || !strcmp(argv[i],"-o")){
	    output = argv[++i];
	}
    }
    if(!load && !store){
	load =1; store=1;
    }
}

FILE * open_output(char * out){
    if(out == NULL)
	return NULL;
    FILE * fout = fopen(out,"w");
    if(fout == NULL) perrEXIT("fopen");
    return fout;
}

void roofline_mem_bench(FILE * out, hwloc_obj_t memory){
    double oi = 0;
    /* Benchmark load */
    if(load){
	roofline_bandwidth(out, memory, ROOFLINE_LOAD);
	if(validate)
	    for(oi = pow(2,-12); oi < pow(2,6); oi*=2){
		roofline_oi(out, memory, ROOFLINE_LOAD, oi);
	    }
    }
    /* Benchmark store */
    if(store){
	roofline_bandwidth(out, memory, ROOFLINE_STORE);
	if(validate)
	    for(oi = pow(2,-12); oi < pow(2,6); oi*=2){
		roofline_oi(out, memory, ROOFLINE_STORE, oi);
	    }
    }
}

int main(int argc, char * argv[]){
    if(roofline_lib_init()==-1)
	errEXIT("roofline library init failure");

    parse_args(argc,argv);
    
    FILE * out = open_output(output);
    if(out==NULL) out = stdout;

    /* print header */
    roofline_mkstr_stack(info,128);
#ifdef USE_OMP
    snprintf(info,sizeof(info), "%5s %5s", "info", "scale");
    roofline_print_header(out, info);
#else
    snprintf(info,sizeof(info), "%5s", "info");
    roofline_print_header(out, info);
#endif

    /* roofline for flops */
    roofline_fpeak(out);
    
    /* roofline every memory obj */
    if(mem == NULL){
	while((mem = roofline_hwloc_get_next_memory(mem)) != NULL){
	    roofline_mem_bench(out, mem);
	}
    }
    else
	roofline_mem_bench(out, mem);
    
    fclose(out);
    roofline_lib_finalize();
    return EXIT_SUCCESS;
}


