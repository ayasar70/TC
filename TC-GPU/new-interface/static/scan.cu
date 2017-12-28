//scan.cu
#include "comm.h"
#include "wtime.h"
#include <stdio.h>
#include "iostream"
#define max_thd 256 
#define max_block 256 

graph * mygraph;

__global__ void warp_binary_kernel
(	//vertex_t*	head,
	//vertex_t*	adj,
	Edge*		workload,
	vertex_t*	adj_list,
	index_t*	begin,
	index_t	Ns,
	index_t	Ne,
	index_t*	count
)
{
	//phase 1, partition
	index_t tid = (threadIdx.x + blockIdx.x * blockDim.x)/32 + Ns;
	index_t mycount=0;
	__shared__ index_t local[max_thd];

	int i = threadIdx.x%32;
	int p = threadIdx.x/32;

	while(tid<Ne){
		vertex_t A = workload[tid].A;
		vertex_t B = workload[tid].B;
		index_t m = begin[A+1]-begin[A];//degree[A];
		index_t n = begin[B+1]-begin[B];//degree[B];
//if(i==0) printf("A %d B %d\n");
		index_t temp;	
		if(m<n){
			temp = A;
			A = B;
			B = temp;
			temp = m;
			m = n;
			n = temp;
		}

		vertex_t* a = &(adj_list[begin[A]]);
		vertex_t* b = &(adj_list[begin[B]]);
		
	//initial cache
		local[p*32+i]=a[i*m/32];	
		__syncthreads();
			
	//search
		int j=i;
		while(j<n){
			vertex_t X = b[j];
			vertex_t Y;
			//phase 1: cache
			int bot = 0;
			int top = 32;
			int r;
			while(top>bot+1){
				r = (top+bot)/2;
				Y = local[p*32+r];
				if(X==Y){
					mycount++;
					bot = top + 32;
//printf("find A %d B %d C %d\n",A,B,X);
				}
				if(X<Y){
					top = r;
				}
				if(X>Y){
					bot = r;
				}
			}
			//phase 2
			bot = bot*m/32;
			top = top*m/32 -1;
			while(top>=bot){
				r = (top+bot)/2;
				Y = a[r];
				if(X==Y){
					mycount++;
//printf("find A %d B %d C %d\n",A,B,X);
				}
				if(X<=Y){
					top = r-1;
				}
				if(X>=Y){
					bot = r+1;
				}
			}
			j += 32;
		
		}
//		tid += GPU_NUM* blockDim.x*gridDim.x/32;
		tid += blockDim.x*gridDim.x/32;
		__syncthreads();
	}

	__syncthreads();
	//reduce
	local[threadIdx.x] = mycount;
	__syncthreads();
	if(threadIdx.x==0){
		index_t val=0;
		for(int i=0; i<blockDim.x; i++){
			val+= local[i];
		}
//		count[blockIdx.x]=val;
		count[blockIdx.x]+=val;
	}
	__syncthreads();

}


__global__ void init_count(index_t* count)
{
	int tid = threadIdx.x;
	count[tid] = 0;
}

__global__ void reduce_kernel(index_t* count)
{
	index_t val = 0;
	for(int i=0; i<max_block; i++){
		val += count[i];
	}
	count[0] = val;
}


//---------------------------------------- cpu function--------------------
//------------------------------------------------------------------



void graph::initDevice(int GPU_id,int Part_id){
//cuda memory copy of partAdj and partBegin
	cudaSetDevice(GPU_id);

	int P=Part_id;
	H_ERR(cudaDeviceSynchronize() );


	vertex_t*	dev_adj;		
	index_t*	dev_begin;	
	index_t*	dev_count;	
	Edge*		buffer0;	
	Edge*		buffer1;	

	index_t EdgeCount = partEdgeCount[P];
	vertex_t* Adj = partAdj[P];
	index_t* Begin  = partBegin[P];
	
	H_ERR(cudaMalloc(&dev_adj, EdgeCount*sizeof(vertex_t)) );
	H_ERR(cudaMalloc(&dev_begin,  (vert_count+1)*sizeof(index_t)) );
	H_ERR(cudaMalloc(&dev_count,    max_block*sizeof(index_t)) );

	H_ERR(cudaMemcpy(dev_adj,    Adj, EdgeCount*sizeof(vertex_t), cudaMemcpyHostToDevice) );
	H_ERR(cudaMemcpy(dev_begin,  Begin,  (vert_count+1)*sizeof(index_t),  cudaMemcpyHostToDevice) );
	
	H_ERR(cudaMalloc(&buffer0,    BufferSize*sizeof(Edge)) );
	H_ERR(cudaMalloc(&buffer1,    BufferSize*sizeof(Edge)) );
	
	gdata[GPU_id].adj	=	dev_adj;
	gdata[GPU_id].begin	=	dev_begin;
	gdata[GPU_id].count	=	dev_count;
	gdata[GPU_id].EdgeBuffer[0]=	buffer0;
	gdata[GPU_id].EdgeBuffer[1]=	buffer1;
	gdata[GPU_id].partition_id =	P;
	gdata[GPU_id].currentBuffer=	0;
	init_count <<<1,max_thd>>>(dev_count);
}

void graph::DeviceCompute(int GPU_id, index_t Chunk_id){
	
	int P = gdata[GPU_id].partition_id;
	
	vertex_t*	dev_adj		=gdata[GPU_id].adj;
	index_t*	dev_begin	=gdata[GPU_id].begin;
	index_t*	dev_count	=gdata[GPU_id].count;
	Edge*		buffer		=gdata[GPU_id].EdgeBuffer[gdata[GPU_id].currentBuffer%2];
	gdata[GPU_id].currentBuffer	=1-gdata[GPU_id].currentBuffer;
	index_t currentBufferSize = BufferSize;
	if(Chunk_id==upperEdgeCount/BufferSize){
		currentBufferSize = upperEdgeCount % BufferSize;
	}
	init_count <<<1,max_thd>>>(dev_count);
	H_ERR(cudaMemcpy(buffer, &OrientedEdge[Chunk_id*BufferSize], currentBufferSize*sizeof(Edge), cudaMemcpyHostToDevice) );
	H_ERR(cudaDeviceSynchronize() );
	warp_binary_kernel<<<max_block,max_thd>>>
	(	buffer,
		dev_adj,
		dev_begin,
		0,
		currentBufferSize,
		dev_count
	);
	//write the result of this chunk back
	H_ERR(cudaDeviceSynchronize() );
	index_t tempcount[max_block];
	index_t mycount=0;
	H_ERR(cudaMemcpy(tempcount, dev_count, max_block*sizeof(index_t), cudaMemcpyDeviceToHost));
	for(int i=0; i<max_block; i++) mycount += tempcount[i];
	ds_count[P][Chunk_id] = mycount;
}

void graph::gpuReduce(int GPU_id){
	vertex_t*	dev_adj		=gdata[GPU_id].adj;
	index_t*	dev_begin	=gdata[GPU_id].begin;
	index_t*	dev_count	=gdata[GPU_id].count;
	Edge**		buffer		=gdata[GPU_id].EdgeBuffer;
//	H_ERR(cudaDeviceSynchronize() );
//	reduce_kernel <<<1,max_thd>>>(dev_count);
//	H_ERR(cudaMemcpy(&count[GPU_id], dev_count, sizeof(index_t), cudaMemcpyDeviceToHost));
//		thd_count += count[i];
//	count[i] = thd_count;
	H_ERR(cudaFree(dev_adj) );
	H_ERR(cudaFree(dev_begin) );
	H_ERR(cudaFree(dev_count) );
	H_ERR(cudaFree(buffer[0]) );
	H_ERR(cudaFree(buffer[1]) );
//	cout<<"GPU "<<GPU_id<<" finished"<<endl;
}

void graph::gpuProc(int GPU_id){
double t0 = wtime();
	index_t total_count=0;
	for(int P=0; P<PART_NUM; P++){
	//	int P = GPU_id/4;
	//	if(PART_NUM > 1) int P = GPU_id%PART_NUM;
		initDevice(GPU_id,P);
		
		index_t chunk_per_gpu = (ChunkNum-1)/GPU_NUM + 1;
		
		
		for(index_t i=GPU_id*chunk_per_gpu; i<(GPU_id+1)*chunk_per_gpu; i++ ){
//		for(index_t i=GPU_id; i<ChunkNum; i+=GPU_NUM ){
//		for(index_t i=GPU_id; i<ChunkNum; i+= 8 ){
//			if(i%8<6)
			if(i<ChunkNum)
			DeviceCompute(GPU_id,i);
		}

		gpuReduce(GPU_id);
		total_count += count[GPU_id];
	}
	count[GPU_id] = total_count;
double t1 = wtime();
cout<<"GPU "<<GPU_id<<" time = "<<t1-t0<<endl;
}
