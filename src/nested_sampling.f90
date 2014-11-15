module nested_sampling_module
    use mpi_module

    implicit none

    integer, parameter :: STARTTAG=0
    integer, parameter :: RUNTAG=1
    integer, parameter :: ENDTAG=2




    contains

    !> Main subroutine for computing a generic nested sampling algorithm
    function NestedSampling(loglikelihood,priors,settings,mpi_communicator) result(output_info)
        use priors_module,     only: prior,prior_log_volume
        use utils_module,      only: logzero,loginf,DBL_FMT,read_resume_unit,stdout_unit,write_dead_unit,TwoPi
        use settings_module
        use utils_module,      only: logsumexp,calc_similarity_matrix
        use read_write_module, only: write_resume_file,write_posterior_file,write_phys_live_points,read_resume_file
        use feedback_module
        use evidence_module,   only: run_time_info,allocate_run_time_info,write_cluster_info
        use chordal_module,    only: SliceSampling
        use random_module,     only: random_integer,random_direction
        use cluster_module,    only: SNN_clustering,NN_clustering
        use generate_module,   only: GenerateLivePointsP,GenerateLivePointsL,GenerateSeed

        implicit none

        interface
            function loglikelihood(theta,phi,context)
                double precision, intent(in),  dimension(:) :: theta
                double precision, intent(out),  dimension(:) :: phi
                integer,          intent(in)                 :: context
                double precision :: loglikelihood
            end function
        end interface

        type(prior), dimension(:), intent(in) :: priors
        type(program_settings), intent(in) :: settings

        integer, intent(in) :: mpi_communicator

        ! Output of the program
        ! 1) log(evidence)
        ! 2) error(log(evidence))
        ! 3) ndead
        ! 4) number of likelihood calls
        ! 5) log(evidence) + log(prior volume)
        double precision, dimension(5) :: output_info



        ! The live points
        double precision, dimension(settings%nTotal,settings%nlive,settings%ncluster) :: live_points
        ! The phantom points
        double precision, dimension(settings%nTotal,settings%nstack,settings%ncluster) :: phantom_points
        ! The number of phantom points in each cluster
        integer, dimension(settings%ncluster) :: nphantom

        ! The evidence storage
        type(run_time_info) :: info

        ! The covariance matrices in the unit hypercube
        double precision, dimension(settings%nDims,settings%nDims,settings%ncluster) :: covmats
        ! The cholesky decompositions in the unit hypercube
        double precision, dimension(settings%nDims,settings%nDims,settings%ncluster) :: choleskys
        ! A single cholesky decomposition for use by the slaves
        double precision, dimension(settings%nDims,settings%nDims) :: cholesky

        double precision, dimension(settings%nDims+settings%nDerived+2,settings%nmax_posterior) :: posterior_array
        integer :: nposterior

        logical :: more_samples_needed

        ! The new-born baby points
        double precision, dimension(settings%nTotal,settings%num_babies)   :: baby_points


        ! Point to seed a new one from
        double precision,    dimension(settings%nTotal)   :: seed_point


        logical :: resume=.false.
        integer :: total_likelihood_calls

        integer :: ndead

        integer, dimension(MPI_STATUS_SIZE) :: mpi_status

        integer :: send_start
        integer :: nprocs
        integer :: myrank
        integer :: root
        logical :: linear_mode


        integer :: i_cluster
        integer :: clusters(settings%nlive)
        integer :: num_new_clusters
        double precision, dimension(settings%nlive,settings%nlive) :: similarity_matrix


        integer :: i_slave
        logical :: slave_sending

        ! This is an incubation stack for babies generated in parallell
        double precision, allocatable, dimension(:,:,:) :: baby_incubator
        integer :: nincubator
        integer :: i_incubator

        integer :: i_dims











        ! Get the number of MPI procedures
        call MPI_COMM_SIZE(mpi_communicator, nprocs, mpierror)
        send_start=nprocs-1
        linear_mode = nprocs==1

        ! Get the MPI label of the current processor
        call MPI_COMM_RANK(mpi_communicator, myrank, mpierror)

        ! Assign the root
        call MPI_ALLREDUCE(myrank,root,1,MPI_INTEGER,MPI_MIN,mpi_communicator,mpierror)

        if(myrank==root) then
            ! ------------------------------------ !
            call write_opening_statement(settings) 
            ! ------------------------------------ !

            ! Allocate the evidence store
            call allocate_run_time_info(settings,info)

            ! Allocate the baby incubator to be an array of live + phantom points the size
            ! of the number of slaves.
            ! Note that it in linear mode (nprocs==1) there is '1 slave' -- the
            ! single node is both master and slave.
            allocate(baby_incubator(settings%nTotal,settings%num_babies,(max(1,nprocs-1))))
            nincubator=0
        end if





        !======= 1) Initialisation =====================================
        ! (i)   generate initial live points by sampling
        !       randomly from the prior (i.e. unit hypercube)
        ! (ii)  Initialise all variables

        !~~~ (i) Generate Live Points ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
        ! Check if we actually want to resume
        inquire(file=trim(settings%file_root)//'.resume',exist=resume)
        resume = settings%read_resume .and. resume

        if(resume) then

            if(myrank==root) then
                ! Check to see whether there's a resume file present, and record in the
                ! variable 'resume'
                if(settings%feedback>=0) write(stdout_unit,'("Resuming from previous run")')
                call read_resume_file(settings,info,live_points,nphantom,phantom_points,&
                    ndead,total_likelihood_calls,nposterior,posterior_array)

            endif ! only root

        else !(.not.resume)

            ! If not resuming, then generate live points in linear or in parallel
            if(linear_mode) then
                live_points(:,:,1) = GenerateLivePointsL(loglikelihood,priors,settings)
            else
                live_points(:,:,1) = GenerateLivePointsP(loglikelihood,priors,settings,mpi_communicator,root)
            end if


            ! Now initialise all of the other variables
            if(myrank==root) then

                ! count up the number of likelihood calls
                total_likelihood_calls = sum(live_points(settings%nlike,:,1))

                ! no dead points 
                ndead = 0

                ! Posterior array
                nposterior = 0                   ! number of points
                posterior_array(1:2,:) = logzero ! loglikelihoods and logweights
                posterior_array(3:,:) = 0d0      ! posterior coordinates

                ! no phantom points
                nphantom = 0

                ! Delete the first outer point
                call delete_outer_point(settings,info,live_points,phantom_points,nphantom,posterior_array,nposterior)

            endif !(myrank==root / myrank/=root)


        end if !(resume / .not.resume)















        if(myrank==root) then


            if(settings%write_resume) &
                call write_resume_file(settings,info,live_points,nphantom,phantom_points,&
                    ndead,total_likelihood_calls,nposterior,posterior_array)



            ! Initialise the covmats at the identity
            covmats = 0d0
            choleskys=0d0
            do i_dims=1,settings%nDims
                covmats(i_dims,i_dims,:) = 1d0
                choleskys(i_dims,i_dims,:) = 1d0
            end do

            ! Calculate the covariance matrices
            covmats = calc_covmats(settings,info,live_points,phantom_points,nphantom)
            ! Calculate the cholesky decomposition
            choleskys = calc_choleskys(covmats(:,:,:info%ncluster_A))

            !======= 2) Main loop body =====================================

            ! -------------------------------------------- !
            call write_started_sampling(settings%feedback)
            ! -------------------------------------------- !

            ! definitely more samples needed than this
            more_samples_needed = .true.

            do while ( more_samples_needed )

                ! (1) Generate a fresh incubation stack of baby_points
                if(settings%feedback>=2) write(stdout_unit,'(" Generating incubation stack ")')

                if(linear_mode) then

                    ! Generate a seed point
                    seed_point = GenerateSeed(settings,info,live_points,i_cluster)

                    ! Choose the cholesky decomposition for the cluster
                    cholesky = choleskys(:,:,i_cluster)

                    ! Generate a new set of points within the likelihood bound of the late point
                    baby_points = SliceSampling(loglikelihood,priors,settings,cholesky,seed_point)

                    ! Add these baby points to the incubator
                    nincubator=1
                    baby_incubator(:,:,nincubator) = baby_points

                else !(.not.linear_mode)

                    ! Recieve any new baby points from any slave currently sending

                    ! Loop through all the slaves
                    nincubator=0
                    do i_slave=1,nprocs-1
                        ! Use MPI_IPROBE to see if the slave at i_slave is sending
                        ! If it is, the logical variable 'slave_sending' is true
                        call MPI_IPROBE(i_slave,MPI_ANY_TAG,mpi_communicator,slave_sending,mpi_status,mpierror)

                        if(slave_sending) then
                            ! If this slave is sending, then recieve the newly generated baby points
                            call MPI_RECV(baby_points,settings%nTotal*settings%num_babies,&
                                MPI_DOUBLE_PRECISION,i_slave,MPI_ANY_TAG,mpi_communicator,mpi_status,mpierror)

                            ! If these baby points aren't nonsense (i.e. the first send) ...
                            if(mpi_status(MPI_TAG)/=STARTTAG) then
                                ! Add these points to the incubator
                                nincubator=nincubator+1
                                baby_incubator(:,:,nincubator) = baby_points
                            end if

                            ! Now generate a new seed point
                            seed_point = GenerateSeed(settings,info,live_points,i_cluster)

                            ! Send the seed point back to this slave
                            call MPI_SEND(seed_point,settings%nTotal,MPI_DOUBLE_PRECISION,i_slave,RUNTAG,mpi_communicator,mpierror)

                            ! Choose the cholesky decomposition for the cluster
                            cholesky = choleskys(:,:,i_cluster)

                            ! Send the cholesky decomposition
                            call MPI_SEND(cholesky,settings%nDims*settings%nDims,MPI_DOUBLE_PRECISION,i_slave,RUNTAG,mpi_communicator,mpierror)

                        end if !(slave_sending)

                    end do !(i_slave=1,nprocs-1)

                end if !(linear_mode / .not.linear_mode)




                ! Now use the incubation stack to update the evidence,live_points,phantom_points & posterior_array
                
                ! Iterate through the incubation stack
                do i_incubator = 1, nincubator

                    ! Save the baby points to a local variable
                    baby_points = baby_incubator(:,:,i_incubator)

                    ! (2) Add the babies to the array, testing to see if these
                    ! constitute a valid point. 
                    if(settings%feedback>=2) write(stdout_unit,'(" Adding babies ")')
                    if( add_babies(settings,info,live_points,phantom_points,nphantom,baby_points) ) then

                        ! Record that we have a new dead point
                        ndead = ndead + 1

                        ! (5) Update the covariance matrix of the distribution of live points
                        if(mod(ndead,settings%nlive) .eq.0) then

                            if(settings%do_clustering) then 

                                if(settings%feedback>=2) write(stdout_unit,'(" Doing Clustering ")')
                                i_cluster=1
                                do while(i_cluster<=info%ncluster_A)
                                    ! For each active cluster, see if it is further sub-clustered

                                    ! Calculate a similarity matrix
                                    similarity_matrix(:info%n(i_cluster),:info%n(i_cluster)) &
                                        = calc_similarity_matrix(live_points(settings%h0:settings%h1,:info%n(i_cluster),i_cluster))

                                    ! Do clustering on this matrix
                                    num_new_clusters = NN_clustering( &
                                        similarity_matrix(:info%n(i_cluster),:info%n(i_cluster)), &
                                        settings%SNN_k,clusters(:info%n(i_cluster)))

                                    ! If we've found new clusters, then we should bifurcate the algorithm at this point
                                    if(num_new_clusters>1) then

                                        if( num_new_clusters+info%ncluster_A>settings%ncluster ) then
                                            call abort_all(" Too many clusters. Consider increasing settings%ncluster")
                                        else if (num_new_clusters + info%ncluster_T > settings%nclustertot ) then
                                            call abort_all(" Too many clusters. Consider increasing settings%nclustertot")
                                        else
                                            write(stdout_unit,'( I, " new clusters found at iteration ", I)') num_new_clusters, ndead
                                            write(*,'(<info%n(i_cluster)>I2)') clusters(:info%n(i_cluster))
                                            call create_new_clusters(settings,info,live_points,phantom_points,nphantom,i_cluster,clusters(:info%n(i_cluster)),num_new_clusters)
                                        end if
                                    else
                                        ! Otherwise move on to the next cluster
                                        i_cluster=i_cluster+1
                                    end if


                                end do

                            end if
                            ! Calculate the covariance matrices
                            covmats = calc_covmats(settings,info,live_points,phantom_points,nphantom)
                            ! Calculate the cholesky decomposition
                            choleskys = calc_choleskys(covmats)

                        end if






                        ! (3) Feedback to command line every nlive iterations

                        ! (4) Update the resume and posterior files every update_resume iterations, or at program termination
                        if (mod(ndead,settings%update_resume) .eq. 0 .or.  more_samples_needed==.false.)  then

                            ! Test to see if we need to finish
                            more_samples_needed =  (live_logZ(settings,info,live_points) > log(settings%precision_criterion) + info%logevidence ) 

                            ! ---------------------------------------------------------------------- !
                            call write_intermediate_results(settings,info,ndead,nphantom,nposterior,&
                                mean_likelihood_calls(settings,info,live_points) ) 
                            ! ---------------------------------------------------------------------- !

                            if(settings%feedback>=2) write(stdout_unit,'(" Writing resume files ")')
                            if(settings%write_resume)        call write_resume_file(settings,info,live_points,nphantom,phantom_points,&
                                                                                    ndead,total_likelihood_calls,nposterior,posterior_array)
                            if(settings%calculate_posterior) call write_posterior_file(settings,posterior_array,info%logevidence,nposterior)  
                            if(settings%write_live)          call write_phys_live_points(settings,info,live_points)

                        end if

                        ! If we've put a limit on the maximum number of iterations, then
                        ! check to see if we've reached this
                        if (settings%max_ndead >0 .and. ndead .ge. settings%max_ndead) more_samples_needed = .false.



                        ! (6] delete the next outer point.
                        if(settings%feedback>=2) write(stdout_unit,'(" Deleting outer point ")')
                        call delete_outer_point(settings,info,live_points,phantom_points,nphantom,posterior_array,nposterior)


                    end if

                end do

            end do ! End main loop



            if(.not.linear_mode) then

                ! Kill off the final slaves
                ! If we're done, then clean up by receiving the last piece of
                ! data from each node (and throw it away) and then send a kill signal back to it
                do i_slave=1,nprocs-1

                    ! Recieve baby point from slave i_slave
                    call MPI_RECV(baby_points,settings%nTotal*settings%num_babies, &
                        MPI_DOUBLE_PRECISION,i_slave,RUNTAG,mpi_communicator,mpi_status,mpierror)

                    ! Send kill signal to slave i_slave
                    call MPI_SEND(seed_point,settings%nTotal, &
                        MPI_DOUBLE_PRECISION,i_slave,ENDTAG,mpi_communicator,mpierror)

                end do

            end if !(.not.linear_mode / linear_mode )


            ! Create the output array
            ! (1) log evidence
            ! (2) Error in the log evidence
            ! (3) Number of dead points
            ! (4) Number of likelihood calls
            ! (5) log(evidence * prior volume)
            output_info(1) = 2*info%logevidence - 0.5*info%logevidence2
            output_info(2) = sqrt(info%logevidence2 - 2*info%logevidence)
            output_info(3) = ndead
            output_info(4) = total_likelihood_calls
            output_info(5) = output_info(1)+prior_log_volume(priors)

            ! ------------------------------------------------------------ !
            call write_final_results(output_info,settings%feedback,priors)
            ! ------------------------------------------------------------ !





        else !(myrank/=root)

            ! These are the slave tasks
            ! -------------------------
            !
            ! This is considerably simpler than that of the master.
            ! All slaves do is:
            ! 1) recieve a seed point from the master
            ! 2) recieve a cholesky decomposition from the master
            ! 3) using the seed and cholesky, generate a new set of baby points
            ! 4) Send the baby points back to the master
            !
            ! There are a couple of subtleties, in that 
            ! BEGIN) at the beginning it needs to send a signal to the master that it's ready to start recieving
            ! END)   at the end it needs to detect when the master has told it the run has finished


            ! BEGIN) On the first loop, send a nonsense set of baby_points
            ! along with the tag STARTTAG to indicate that we're ready
            ! to start receiving
            baby_points = 0d0
            call MPI_SEND(baby_points,settings%nTotal*settings%num_babies, &
                MPI_DOUBLE_PRECISION,root,STARTTAG,mpi_communicator,mpierror)

            do while(.true.)

                ! 1) Listen for a seed point being sent by the master
                call MPI_RECV(seed_point,settings%nTotal, &
                    MPI_DOUBLE_PRECISION,root,MPI_ANY_TAG,mpi_communicator,mpi_status,mpierror)

                ! END) If we receive a kill signal, then exit the loop
                if(mpi_status(MPI_TAG)==ENDTAG) exit

                ! 2) Listen for the cholesky decomposition sent by the master
                call MPI_RECV(cholesky,settings%nDims*settings%nDims, &
                    MPI_DOUBLE_PRECISION,root,RUNTAG,mpi_communicator,mpi_status,mpierror)

                ! 3) Generate a new set of baby points
                baby_points = SliceSampling(loglikelihood,priors,settings,cholesky,seed_point)

                ! 4) Send the baby points back
                call MPI_SEND(baby_points,settings%nTotal*settings%num_babies, &
                    MPI_DOUBLE_PRECISION,root,RUNTAG,mpi_communicator,mpierror)

            end do

        end if !(myrank==root / myrank/=root) 




    end function NestedSampling







    subroutine create_new_clusters(settings,info,live_points,phantom_points,nphantom,i_cluster,clusters,num_new_clusters)
        use settings_module,   only: program_settings
        use evidence_module,   only: run_time_info,bifurcate_evidence
        implicit none

        type(program_settings), intent(in) :: settings
        type(run_time_info), intent(inout) :: info

        double precision, dimension(settings%nTotal,settings%nlive,settings%ncluster),intent(inout)   :: live_points
        double precision, dimension(settings%nTotal,settings%nstack,settings%ncluster),intent(inout)  :: phantom_points
        integer, dimension(settings%ncluster),intent(inout) :: nphantom

        integer, intent(in)                             :: i_cluster
        integer,dimension(info%n(i_cluster)),intent(in) :: clusters
        integer, intent(in)                             :: num_new_clusters

        double precision, dimension(settings%nTotal,settings%nstack,settings%ncluster) :: temp_phantoms
        integer, dimension(settings%ncluster) :: temp_nphantom

        ! Temporary live points
        double precision, dimension(settings%nTotal,info%n(i_cluster)) :: lives
        integer :: nlives
        integer :: i_live

        integer :: i_phantom

        integer :: j_cluster,k_cluster

        integer, dimension(num_new_clusters) :: ni
        integer :: ncluster_A_old

        ! Get the lives to split
        nlives = info%n(i_cluster)
        lives  = live_points(:,:,i_cluster)

        ! Create a temporary set of phantom points for re-assigning to clusters
        ncluster_A_old= info%ncluster_A
        temp_phantoms = phantom_points
        temp_nphantom = nphantom


        ! Set the number of points in the new clusters to 0 initially
        ni = 0

        ! Split the live points stored in lives into their new clusters
        do i_live=1,nlives

            ! Iterate the number of points in cluster 'clusters(i_live)'
            ni(clusters(i_live))= ni(clusters(i_live)) + 1

            ! Add the 'i_live' point to the 'clusters(i_live)' cluster from the end
            live_points(:,ni(clusters(i_live)),clusters(i_live) + info%ncluster_A) = lives(:,i_live)
        end do

        ! Update the info variable for these new clusters
        call bifurcate_evidence(info,i_cluster,ni)

        ! Delete the old cluster
        call reorganise_clusters(settings,info,live_points,phantom_points,nphantom,i_cluster) 

        ! Reassign all of the phantom points
        ! set the number of phantoms to zero
        nphantom=0

        ! Reassign the phantom points
        do j_cluster=1,ncluster_A_old
            do i_phantom=1,temp_nphantom(j_cluster)
                ! Identify the cluster this phantom point belongs to
                k_cluster = identify_cluster(settings,info,temp_phantoms(:,i_phantom,j_cluster),live_points)
                nphantom(k_cluster) = nphantom(k_cluster) + 1

                phantom_points(:,nphantom(k_cluster),k_cluster) = temp_phantoms(:,i_phantom,j_cluster)
            end do
        end do


    end subroutine create_new_clusters



    function identify_cluster(settings,info,point,live_points) result(cluster)
        use settings_module,   only: program_settings
        use evidence_module,   only: run_time_info
        use utils_module,      only: loginf,distance2
        implicit none

        type(program_settings), intent(in) :: settings
        type(run_time_info), intent(inout) :: info

        double precision, dimension(settings%nTotal),intent(in)   :: point
        double precision, dimension(settings%nTotal,settings%nlive,settings%ncluster),intent(in)   :: live_points

        integer :: cluster

        integer :: i_cluster
        integer :: i_live

        double precision :: temp_distance2
        double precision :: closest_distance2

        closest_distance2=loginf

        ! Find the cluster this point is nearest to
        do i_cluster=1,info%ncluster_A
            do i_live=1,info%n(i_cluster)
                temp_distance2 = distance2(point(settings%h0:settings%h1),live_points(settings%h0:settings%h1,i_live,i_cluster) )
                if(temp_distance2 < closest_distance2) then
                    cluster = i_cluster
                    closest_distance2 = temp_distance2
                end if
            end do
        end do

    end function identify_cluster














    function add_babies(settings,info,live_points,phantom_points,nphantom,baby_points) result(babies_added)
        use settings_module,   only: program_settings
        use evidence_module,   only: run_time_info
        implicit none

        type(program_settings), intent(in) :: settings
        type(run_time_info), intent(inout) :: info

        double precision, dimension(settings%nTotal,settings%nlive,settings%ncluster),intent(inout)   :: live_points
        double precision, dimension(settings%nTotal,settings%nstack,settings%ncluster),intent(inout)  :: phantom_points
        integer, dimension(settings%ncluster),intent(inout) :: nphantom
        double precision, dimension(settings%nTotal,settings%num_babies),intent(in)                   :: baby_points

        logical :: babies_added

        integer,dimension(settings%num_babies) :: baby_cluster
        integer :: i_cluster
        integer :: i_baby

        ! Identify the clusters
        if(settings%do_clustering .and. info%ncluster_A>1 ) then
            do i_baby=1,settings%num_babies
                baby_cluster(i_baby) = identify_cluster(settings,info,baby_points(:,i_baby),live_points)
            end do
        else
            ! No clustering needed
            baby_cluster = 1
        end if

        ! If the baby has a likelihood >= contour, then add it to the end of the
        ! live points (this is where the lowest likelihood point is found).
        i_baby = settings%num_babies
        i_cluster = baby_cluster(i_baby)
        if( baby_points(settings%l0,i_baby) >= info%logL(i_cluster) ) then

            ! record the increase in the number of live points for this cluster
            info%n(i_cluster) = info%n(i_cluster) + 1

            ! Add it to the end of the live points in cluster 'i_cluster'
            live_points(:,info%n(i_cluster),i_cluster) = baby_points(:,settings%num_babies)

            ! Record that we've added a baby point
            babies_added=.true.
        else
            babies_added=.false.
        end if

        ! Now add all of the rest to the end of the phantom array (these will be pruned later if necessary)
        do i_baby=1,settings%num_babies-1
            ! Note the cluster number
            i_cluster = baby_cluster(i_baby)

            ! record the increase in number of phantom points in that cluster
            nphantom(i_cluster) = nphantom(i_cluster) + 1

            ! Add the baby point to the correct part of the phantom array
            phantom_points(:,nphantom(i_cluster),i_cluster) = baby_points(:,i_baby)

        end do

    end function add_babies



    subroutine delete_outer_point(settings,info,live_points,phantom_points,nphantom,posterior_array,nposterior) 
        use settings_module,   only: program_settings
        use evidence_module,   only: run_time_info,update_evidence,delete_evidence
        implicit none

        type(program_settings), intent(in) :: settings
        type(run_time_info), intent(inout) :: info

        double precision, dimension(settings%nTotal,settings%nlive,settings%ncluster),intent(inout)   :: live_points
        double precision, dimension(settings%nTotal,settings%nstack,settings%ncluster),intent(inout)  :: phantom_points
        integer, dimension(settings%ncluster),intent(inout) :: nphantom

        double precision, dimension(settings%nDims+settings%nDerived+2,settings%nmax_posterior),intent(inout) :: posterior_array
        integer,intent(inout) :: nposterior

        double precision :: min_loglike
        integer :: min_cluster

        double precision, dimension(settings%nTotal) :: dead_point

        double precision :: logweight


        ! Find the outermost point, and rearrange the live points to 'delete'
        ! the outermost point
        dead_point = find_outer_point(settings,info,live_points,min_loglike,min_cluster)

        ! Get the logweighting for use in posterior calculation
        logweight = info%logX(min_cluster) - log( info%n(min_cluster) + 1d0 )

        ! Update the evidence and other stored information 
        call update_evidence(info,min_cluster,min_loglike)

        ! Update the posterior and phantom_arrays
        call update_posterior_and_phantom(settings,posterior_array,nposterior,dead_point,phantom_points,nphantom,min_cluster,min_loglike,logweight) 
        ! Decrease the chord estimate for this cluster
        !live_points(settings%last_chord,:,min_cluster) = live_points(settings%last_chord,:,min_cluster) *info%n(min_cluster) / (info%n(min_cluster) + 1d0) 

        ! If we've deleted a cluster, we should re-organise live and phantom points
        if(info%n(min_cluster)==0) then
            write(*,'(" Deleting cluster", I4)') min_cluster
            call reorganise_clusters(settings,info,live_points,phantom_points,nphantom,min_cluster)
        end if

    end subroutine delete_outer_point


    subroutine reorganise_clusters(settings,info,live_points,phantom_points,nphantom,min_cluster)
        use settings_module,   only: program_settings
        use evidence_module,   only: run_time_info,delete_evidence
        implicit none

        type(program_settings), intent(in) :: settings
        type(run_time_info), intent(inout) :: info

        double precision, dimension(settings%nTotal,settings%nlive,settings%ncluster),intent(inout)   :: live_points
        double precision, dimension(settings%nTotal,settings%nstack,settings%ncluster),intent(inout)  :: phantom_points
        integer, dimension(settings%ncluster),intent(inout) :: nphantom

        integer,intent(in) :: min_cluster


        ! Cyclically shift the active points down one
        live_points(   :,:,min_cluster:info%ncluster_A) = cshift(live_points(   :,:,min_cluster:info%ncluster_A),shift=1,dim=3)
        phantom_points(:,:,min_cluster:info%ncluster_A) = cshift(phantom_points(:,:,min_cluster:info%ncluster_A),shift=1,dim=3)
        nphantom(          min_cluster:info%ncluster_A) = cshift(nphantom(          min_cluster:info%ncluster_A),shift=1,dim=1) 

        ! Update the evidence
        call delete_evidence(info,min_cluster)

    end subroutine reorganise_clusters





    function find_outer_point(settings,info,live_points,min_loglike,min_cluster) result(dead_point)
        use settings_module,   only: program_settings
        use evidence_module,   only: run_time_info
        use utils_module,      only: loginf
        implicit none

        ! Inputs
        type(program_settings), intent(in) :: settings
        type(run_time_info), intent(in) :: info
        double precision, dimension(settings%nTotal,settings%nlive,settings%ncluster),intent(inout)   :: live_points
        double precision, dimension(settings%nTotal) :: dead_point

        double precision, intent(out)   :: min_loglike
        integer, intent(out)            :: min_cluster

        ! Local variables
        integer :: i_cluster
        double precision :: loglike
        integer          :: pos(1)
        integer          :: min_pos


        ! Initialise min_loglike at the largest possible value
        min_loglike = loginf

        ! Iterate through the clusters to find the cluster with the lowest
        ! outermost loglikelihood
        do i_cluster=1,info%ncluster_A

            ! Find the position of the lowest loglikelihood point in cluster 'i_cluster'
            pos = minloc(live_points(settings%l0,:info%n(i_cluster),i_cluster))
            ! Find that lowest loglikelihood
            loglike = live_points(settings%l0,pos(1),i_cluster)

            ! If this loglikelihood is lower than the current lowest, then update the outputs
            if(loglike < min_loglike) then
                min_loglike = loglike
                min_cluster = i_cluster
                min_pos     = pos(1)
            end if

        end do

        ! Record the point that has just died
        dead_point = live_points(:,min_pos,min_cluster)

        ! move the end point of min_cluster to replace the outermost point
        live_points(:,min_pos,min_cluster) = live_points(:,info%n(min_cluster),min_cluster)

    end function find_outer_point


    !> This function runs through the phantom array, removing any points from
    !! the relevant cluster that are now below the loglikelihood contour. It
    !! adds a fraction of the discarded phantoms to the posterior array. Finally
    !! it cleans the posterior array, by removing any points that are obviously
    !! too low in weight
    subroutine update_posterior_and_phantom(settings,posterior_array,nposterior,dead_point,phantom_points,nphantom,min_cluster,min_loglike,logweight)
        use settings_module,   only: program_settings
        use utils_module,      only: stdout_unit
        use random_module,     only: random_real
        implicit none

        ! Inputs
        type(program_settings), intent(in) :: settings
        double precision, dimension(settings%nTotal),intent(in) :: dead_point
        integer, intent(in)            :: min_cluster
        double precision, intent(in)            :: min_loglike
        double precision, intent(in)            :: logweight

        ! Outputs
        double precision, dimension(settings%nDims+settings%nDerived+2,settings%nmax_posterior),intent(inout) :: posterior_array
        integer,intent(inout) :: nposterior
        double precision, dimension(settings%nTotal,settings%nstack,settings%ncluster),intent(inout)  :: phantom_points
        integer, dimension(settings%ncluster),intent(inout) :: nphantom


        ! Local variables
        double precision, dimension(settings%nDims+settings%nDerived+2) :: posterior_point
        double precision :: max_logweight
        double precision :: lognmax_posterior

        integer :: i_phantom
        integer :: i_posterior






        if(settings%calculate_posterior) then
            ! Now update the posterior information for the dead point
            !   - calculate the new posterior point
            posterior_point = calc_posterior_point(settings,dead_point,logweight)
            !   - increase the number of posterior points by 1, and check that we're
            !     not over the limit
            nposterior=nposterior+1
            
            if(nposterior>settings%nmax_posterior) call abort_all(" Too many posterior points. Consider increasing nmax_posterior ")

            !   - add the posterior point to the array
            posterior_array(:,nposterior) = posterior_point
        end if





        ! Now run through the stack and strip out any points that are less
        ! than the min_loglike, replacing them with points drawn from
        ! the end 
        i_phantom=1
        do while(i_phantom<=nphantom(min_cluster))
            if( phantom_points(settings%l0,i_phantom,min_cluster) < min_loglike ) then

                if(settings%calculate_posterior .and. random_real() < settings%thin_posterior) then
                    ! Now update the posterior information
                    !   - calculate the new posterior point
                    posterior_point = calc_posterior_point(settings,phantom_points(:,i_phantom,min_cluster),logweight)
                    !   - increase the number of posterior points by 1, and check that we're
                    !     not over the limit
                    nposterior=nposterior+1

                    if(nposterior>settings%nmax_posterior) call abort_all(" Too many posterior points. Consider increasing nmax_posterior ")

                    !   - add the posterior point to the array
                    posterior_array(:,nposterior) = posterior_point
                end if

                ! Overwrite the discarded point with a point from the end...
                phantom_points(:,i_phantom,min_cluster) = phantom_points(:,nphantom(min_cluster),min_cluster)
                ! ...and reduce the number of phantom points
                nphantom(min_cluster)=nphantom(min_cluster)-1
            else
                i_phantom=i_phantom+1
            end if
        end do




        if(settings%calculate_posterior) then

            ! Clean out the posterior array

            ! Find the maximum weighted posterior point
            max_logweight = maxval(posterior_array(1,:nposterior))

            lognmax_posterior = log(settings%nmax_posterior+0d0)

            i_posterior=1
            do while(i_posterior<=nposterior)
                if( posterior_array(1,i_posterior) - max_logweight + lognmax_posterior < 0 ) then
                    ! Overwrite the discarded point with a point from the end...
                    posterior_array(:,i_posterior) = posterior_array(:,nposterior)
                    ! ...and reduce the stack size
                    nposterior=nposterior-1
                else
                    i_posterior=i_posterior+1
                end if
            end do
        end if

    end subroutine update_posterior_and_phantom



    !> Calculate a posterior point from a live/phantom point, suitable for
    !! adding to a .txt file
    function calc_posterior_point(settings,point,logweight) result(posterior_point)
        use settings_module,   only: program_settings
        implicit none

        type(program_settings), intent(in) :: settings
        double precision, dimension(settings%nTotal),intent(in) :: point
        double precision,intent(in) :: logweight
        double precision, dimension(settings%nDims+settings%nDerived+2) :: posterior_point


        ! Un-normalised weighting (needs to be unnormalised since the evidence is only correct at the end)
        posterior_point(1)  = point(settings%l0) + logweight
        ! Likelihood
        posterior_point(2)  = point(settings%l0)
        ! Physical parameters
        posterior_point(2+1:2+settings%nDims) = point(settings%p0:settings%p1)
        ! Derived parameters
        posterior_point(2+settings%nDims+1:2+settings%nDims+settings%nDerived) = point(settings%d0:settings%d1)

    end function calc_posterior_point














    function calc_covmats(settings,info,live_points,phantom_points,nphantom) result(covmats)
        use settings_module,   only: program_settings
        use evidence_module,   only: run_time_info
        use utils_module,      only: calc_covmat
        implicit none

        type(program_settings), intent(in) :: settings
        type(run_time_info),intent(in) :: info
        double precision, dimension(settings%nTotal,settings%nlive,settings%ncluster),intent(in) :: live_points
        double precision, dimension(settings%nTotal,settings%nstack,settings%ncluster),intent(in) :: phantom_points
        integer, dimension(settings%ncluster),intent(in) :: nphantom

        double precision, dimension(settings%nDims,settings%nDims,settings%ncluster) :: covmats

        integer :: i

        covmats = 0 

        do i=1,info%ncluster_A
            if(info%n(i)+nphantom(i) >= settings%nDims*(settings%nDims+1)/2) then
                covmats(:,:,i) = calc_covmat(&
                    live_points(settings%h0:settings%h1,:info%n(i),i),&
                    phantom_points(settings%h0:settings%h1,:nphantom(i),i)&
                    )
            end if
        end do

    end function calc_covmats

    function calc_choleskys(covmats) result(choleskys)
        use utils_module, only: calc_cholesky
        implicit none
        double precision, intent(in), dimension(:,:,:) :: covmats
        double precision, dimension(size(covmats,1),size(covmats,2),size(covmats,3)) :: choleskys

        integer :: i

        choleskys=0d0

        do i=1,size(covmats,3)
            choleskys(:,:,i) = calc_cholesky( covmats(:,:,i) )
        end do

    end function calc_choleskys


    function mean_likelihood_calls(settings,info,live_points) 
        use settings_module,   only: program_settings
        use evidence_module,   only: run_time_info
        implicit none
        type(program_settings), intent(in) :: settings
        type(run_time_info),intent(in) :: info
        double precision, dimension(settings%nTotal,settings%nlive,settings%ncluster),intent(in) :: live_points
        
        double precision mean_likelihood_calls
        integer i_cluster

        mean_likelihood_calls=0d0

        do i_cluster=1,info%ncluster_A
            mean_likelihood_calls = mean_likelihood_calls + sum(live_points(settings%nlike,:info%n(i_cluster),i_cluster))
        end do

        mean_likelihood_calls = mean_likelihood_calls/(settings%nlive + 0d0)


    end function mean_likelihood_calls 

    function live_logZ(settings,info,live_points) 
        use settings_module,   only: program_settings
        use evidence_module,   only: run_time_info
        use utils_module,      only: logzero,logsumexp,logincexp
        implicit none
        type(program_settings), intent(in) :: settings
        type(run_time_info),intent(in) :: info
        double precision, dimension(settings%nTotal,settings%nlive,settings%ncluster),intent(in) :: live_points
        
        double precision live_logZ
        integer i_cluster

        ! Sum up the live log evidence
        live_logZ=logzero

        do i_cluster=1,info%ncluster_A

            call logincexp( live_logZ, logsumexp(live_points(settings%l0,:info%n(i_cluster),i_cluster)) &
                                       - log( info%n(i_cluster) + 0d0) &
                                       + info%logX(i_cluster)   )


        end do


    end function live_logZ




    function mean_w(settings,info,live_points) 
        use settings_module,   only: program_settings
        use evidence_module,   only: run_time_info
        use utils_module,      only: loginf,logzero
        implicit none
        type(program_settings), intent(in) :: settings
        type(run_time_info),intent(in) :: info
        double precision, dimension(settings%nTotal,settings%nlive,settings%ncluster),intent(in) :: live_points
        
        double precision mean_w(3)
        integer i_cluster

        mean_w(1)=0
        mean_w(2)=logzero
        mean_w(3)=loginf

        do i_cluster=1,info%ncluster_A
            mean_w(1) = mean_w(1) + sum(live_points(settings%last_chord,:info%n(i_cluster),i_cluster))
            mean_w(2) = max(mean_w(2),maxval(live_points(settings%last_chord,:info%n(i_cluster),i_cluster)))
            mean_w(3) = min(mean_w(3),minval(live_points(settings%last_chord,:info%n(i_cluster),i_cluster)))
        end do



    end function mean_w 





end module nested_sampling_module