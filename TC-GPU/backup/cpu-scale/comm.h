#ifndef	COMM_HEADER
#define	COMM_HEADER
#include <iostream>
#include <fstream>
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>

//--------------------------
//typedef 	unsigned long int 	index_t;
//typedef		unsigned int		vertex_t;

typedef 	long int 	index_t;
typedef		int		vertex_t;
//--------------------------------
#define PART_PER_GPU 	1//fixed in this version

#define BufferSize	16777216 //16M edges, or 64MB*2 for edge buffer
#define GPU_NUM 	0	
#define PART_NUM 	1
#define GPU_PER_PART	1
#define T		56
//int GPU_PER_PART 	=GPU_NUM/PART_NUM; //global variable, =1 when part# is larger than GPU#, or part#/gpu#
//int GPU_NUM=6; 
//int PART_NUM=6; 

inline off_t fsize(const char *filename) {
	struct stat st;
	if (stat(filename, &st) == 0){
		return st.st_size;
	}
	return -1;
}


static void HandleError( cudaError_t err,
                         const char *file,
                         int line ) {
    if (err != cudaSuccess) {
        printf( "%s in %s at line %d\n", \
        cudaGetErrorString( err ),
                file, line );
        exit( EXIT_FAILURE );
    }
}
#define H_ERR( err ) \
  (HandleError( err, __FILE__, __LINE__ ))

typedef struct EDGE{
	vertex_t A;
	vertex_t B;
} Edge;
typedef struct GPUData{
	int id;
	int partition_id;

	int currentBuffer;

	vertex_t * adj;
	index_t  * begin;
	index_t  * count;
	
	Edge **EdgeBuffer;

} GPU_data;



#endif
