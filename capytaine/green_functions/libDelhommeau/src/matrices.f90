! Copyright (C) 2017-2024 Matthieu Ancellin
! See LICENSE file at <https://github.com/capytaine/libDelhommeau>

MODULE MATRICES

  USE FLOATING_POINT_PRECISION, ONLY: PRE
  USE CONSTANTS

  USE GREEN_RANKINE
  USE GREEN_WAVE

  IMPLICIT NONE

CONTAINS

  ! =====================================================================

  SUBROUTINE BUILD_MATRICES(                             &
      nb_faces_1, centers_1, dot_product_normals,        &
      nb_vertices_2, nb_faces_2, vertices_2, faces_2,    &
      centers_2, normals_2, areas_2, radiuses_2,         &
      nb_quad_points, quad_points, quad_weights,         &
      wavenumber, depth,                                 &
      coeffs,                                            &
      tabulation_nb_integration_points,                  &
      tabulation_grid_shape,                             &
      tabulated_r_range, tabulated_z_range,              &
      tabulated_integrals,                               &
      finite_depth_method, prony_decomposition, dispersion_roots,  &
      same_body, gf_singularities, adjoint_double_layer, &
      S, K)

    ! Mesh data
    INTEGER,                                     INTENT(IN) :: nb_faces_1, nb_faces_2, nb_vertices_2
    REAL(KIND=PRE), DIMENSION(nb_faces_1, 3),    INTENT(IN) :: centers_1
    REAL(KIND=PRE), DIMENSION(:, :),             INTENT(IN) :: dot_product_normals
    REAL(KIND=PRE), DIMENSION(nb_vertices_2, 3), INTENT(IN) :: vertices_2
    INTEGER,        DIMENSION(nb_faces_2, 4),    INTENT(IN) :: faces_2
    REAL(KIND=PRE), DIMENSION(nb_faces_2, 3),    INTENT(IN) :: centers_2, normals_2
    REAL(KIND=PRE), DIMENSION(nb_faces_2),       INTENT(IN) :: areas_2, radiuses_2

    ! dot_product_normals might be identical to normals_2, especially when adjoint_double_layer is False.
    ! The former is used when computing the dot product with the normal vector in the double layer or adjoint double layer operator
    ! (D or K matrices). The latter is only used when computing the exact formula to integrate the Rankine part of the Green
    ! function over a face.
    ! Hence, both variables fulfill different role, and may or may not be identical.

    INTEGER,                                                  INTENT(IN) :: nb_quad_points
    REAL(KIND=PRE), DIMENSION(nb_faces_2, nb_quad_points, 3), INTENT(IN) :: quad_points
    REAL(KIND=PRE), DIMENSION(nb_faces_2, nb_quad_points),    INTENT(IN) :: quad_weights

    ! Solver parameters
    LOGICAL,                                  INTENT(IN) :: same_body
    INTEGER,                                  INTENT(IN) :: gf_singularities
    LOGICAL,                                  INTENT(IN) :: adjoint_double_layer
    REAL(KIND=PRE), DIMENSION(3)                         :: coeffs

    REAL(KIND=PRE),                           INTENT(IN) :: wavenumber, depth

    ! Tabulated values for the wave part of the Green function
    INTEGER,                                  INTENT(IN) :: tabulation_grid_shape
    INTEGER,                                  INTENT(IN) :: tabulation_nb_integration_points
    REAL(KIND=PRE), DIMENSION(:),             INTENT(IN) :: tabulated_r_range
    REAL(KIND=PRE), DIMENSION(:),             INTENT(IN) :: tabulated_z_range
    REAL(KIND=PRE), DIMENSION(:, :, :),       INTENT(IN) :: tabulated_integrals

    integer,                                  intent(in) :: finite_depth_method
    real(kind=pre), dimension(:, :),          intent(in) :: prony_decomposition  ! For Delhommeau's finite depth, dummy otherwise
    real(kind=pre), dimension(:),             intent(in) :: dispersion_roots  ! For FinGreen3D, dummy otherwise

    ! Outputs
    COMPLEX(KIND=PRE), DIMENSION(:, :), INTENT(INOUT) :: S  ! integrals of the Green function
    COMPLEX(KIND=PRE), DIMENSION(:, :, :), INTENT(INOUT) :: K  ! integrals of the gradient of the Green function

    ! Local variables
    INTEGER                         :: I, J
    REAL(KIND=PRE)                  :: int_G_Rankine, diagonal_coef
    REAL(KIND=PRE), DIMENSION(3)    :: int_nablaG_Rankine
    COMPLEX(KIND=PRE)               :: int_G, int_G_wave
    COMPLEX(KIND=PRE), DIMENSION(3) :: int_nablaG, int_nablaG_wave
    LOGICAL :: use_symmetry_of_wave_part, derivative_with_respect_to_first_variable

    ! use_symmetry_of_wave_part = ((SAME_BODY) .AND. (nb_quad_points == 1)   &
    !                              .AND. (.not. (is_infinity(depth) .and. (finite_depth_method == FINGREEN3D))))
    use_symmetry_of_wave_part = .false.

    derivative_with_respect_to_first_variable = adjoint_double_layer
    ! When computing the adjoint double layer operator (K), the derivative of the Green function is computed with respect to its
    ! first variable (field point, often written x, or sometimes M in this code).
    ! When computing the double layer operator (D), the derivative of the Green function is computed with respect to its second
    ! variable (source point, often written xi, or sometimes M' in this code).

    coeffs(:) = coeffs(:)/(-4*PI)  ! Factored out coefficient

    !$OMP PARALLEL DO SCHEDULE(DYNAMIC) &
    !$OMP&  PRIVATE(J, I, int_G, int_nablaG, int_G_Rankine, int_nablaG_Rankine, diagonal_coef, &
    !$OMP&          int_G_wave, int_nablaG_wave)
    DO J = 1, nb_faces_2
      DO I = 1, nb_faces_1

        int_G = CZERO
        int_nablaG(:) = CZERO

        !!!!!!!!!!!!!!!!!!!
        !  Diagonal term  !
        !!!!!!!!!!!!!!!!!!!
        IF (I==J .and. same_body) THEN

          if (abs(centers_2(j, 3)) < 1e-8) then  ! Panel on the free surface
            diagonal_coef = ONE
          else
            diagonal_coef = ONE/2
          endif

          int_nablaG(:) = int_nablaG(:) + diagonal_coef * dot_product_normals(I, :)
          ! if (.not. adjoint_double_layer) then we should have used the Jth normal instead of the Ith,
          ! such that later the dot product with dot_product_normals(J, :) gives 1.
          ! Except that here, I==J, so there is no need to branch based on adjoint_double_layer.
        ENDIF

        !!!!!!!!!!!!!!!!!!
        !  Rankine part  !
        !!!!!!!!!!!!!!!!!!
        if (coeffs(1) .NE. ZERO) then

          call integral_of_Rankine(                    &
            centers_1(I, :),                           &
            vertices_2(faces_2(J, :), :),              &
            centers_2(J, :),                           &
            normals_2(J, :),                           &
            areas_2(J),                                &
            radiuses_2(J),                             &
            derivative_with_respect_to_first_variable, &
            int_G_Rankine, int_nablaG_Rankine          &
            )

          int_G = int_G + coeffs(1) * int_G_Rankine
          int_nablaG(:) = int_nablaG(:) + coeffs(1) * int_nablaG_Rankine(:)
        endif


        !!!!!!!!!!!!!!!!!!!!!!!!!!!!
        !  Reflected Rankine part  !
        !!!!!!!!!!!!!!!!!!!!!!!!!!!!
        if ((coeffs(2) .NE. ZERO) .or. &
            ((gf_singularities == LOW_FREQ_WITH_RANKINE_PART) .and. (coeffs(3) .NE. ZERO))) then

          if ((.not. is_infinity(depth)) .and. (finite_depth_method == LEGACY_FINITE_DEPTH)) then
            ! Dubious legacy behavior in finite depth...
            call one_point_integral_of_reflected_Rankine( &
              centers_1(I, :),                            &
              centers_2(J, :),                            &
              areas_2(J),                                 &
              derivative_with_respect_to_first_variable,  &
              [-ONE, ZERO],                               &
              int_G_Rankine,                              &
              int_nablaG_Rankine                          &
            )
          else
            call integral_of_reflected_Rankine(          &
              centers_1(I, :),                           &
              vertices_2(faces_2(J, :), :),              &
              centers_2(J, :),                           &
              normals_2(J, :),                           &
              areas_2(J),                                &
              radiuses_2(J),                             &
              derivative_with_respect_to_first_variable, &
              [-ONE, ZERO],                              &
              int_G_Rankine,                             &
              int_nablaG_Rankine                         &
              )
          endif
          int_G = int_G + coeffs(2) * int_G_Rankine
          int_nablaG(:) = int_nablaG(:) + coeffs(2) * int_nablaG_Rankine(:)

          if (gf_singularities == LOW_FREQ_WITH_RANKINE_PART) then
            int_nablaG(3) = int_nablaG(3) + coeffs(3) * 2*wavenumber * int_G_Rankine
          endif

          !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
          !  Supplementary Rankine parts in finite depth  !
          !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
          if (.not. (is_infinity(depth)) .and. (finite_depth_method .ne. FINGREEN3D_METHOD)) then
            ! 1. Reflection through sea bottom
            call integral_of_reflected_Rankine(          &
              centers_1(I, :),                           &
              vertices_2(faces_2(J, :), :),              &
              centers_2(J, :),                           &
              normals_2(J, :),                           &
              areas_2(J),                                &
              radiuses_2(J),                             &
              derivative_with_respect_to_first_variable, &
              [-ONE, -2*depth],                          &
              int_G_Rankine, int_nablaG_Rankine          &
              )
            int_G = int_G + coeffs(2) * int_G_Rankine
            int_nablaG(:) = int_nablaG(:) + coeffs(2) * int_nablaG_Rankine(:)

            ! 2. Reflection through sea bottom and free surface
            call one_point_integral_of_reflected_Rankine( &
              centers_1(I, :),                            &
              centers_2(J, :),                            &
              areas_2(J),                                 &
              derivative_with_respect_to_first_variable,  &
              [ONE, -2*depth],                            &
              int_G_Rankine, int_nablaG_Rankine           &
              )
            int_G = int_G + coeffs(2) * int_G_Rankine
            int_nablaG(:) = int_nablaG(:) + coeffs(2) * int_nablaG_Rankine(:)

            ! 3. Reflection through free surface and sea bottom
            call one_point_integral_of_reflected_Rankine( &
              centers_1(I, :),                            &
              centers_2(J, :),                            &
              areas_2(J),                                 &
              derivative_with_respect_to_first_variable,  &
              [ONE, 2*depth],                             &
              int_G_Rankine, int_nablaG_Rankine           &
              )
            int_G = int_G + coeffs(2) * int_G_Rankine
            int_nablaG(:) = int_nablaG(:) + coeffs(2) * int_nablaG_Rankine(:)

            ! 4. Reflection through sea bottom and free surface and sea bottom again
            call one_point_integral_of_reflected_rankine( &
              centers_1(I, :),                            &
              centers_2(J, :),                            &
              areas_2(J),                                 &
              derivative_with_respect_to_first_variable,  &
              [-ONE, -4*depth],                           &
              int_G_Rankine, int_nablaG_Rankine           &
              )
            int_G = int_G + coeffs(2) * int_G_Rankine
            int_nablaG(:) = int_nablaG(:) + coeffs(2) * int_nablaG_Rankine(:)

          endif

        endif

        !!!!!!!!!!!!!!!
        !  Wave part  !
        !!!!!!!!!!!!!!!
        if ((coeffs(3) .ne. zero) .and. (.not. use_symmetry_of_wave_part)) then

          call integral_of_wave_part(                                  &
            centers_1(I, :),                                           &
            vertices_2(faces_2(J, :), :),                              &
            centers_2(J, :),                                           &
            normals_2(J, :),                                           &
            areas_2(J),                                                &
            radiuses_2(J),                                             &
            quad_points(J, :, :), quad_weights(J, :),                  &
            wavenumber, depth,                                         &
            tabulation_nb_integration_points, tabulation_grid_shape,   &
            tabulated_r_range, tabulated_z_range, tabulated_integrals, &
            gf_singularities,                                          &
            finite_depth_method, prony_decomposition, dispersion_roots,&
            derivative_with_respect_to_first_variable,                 &
            int_G_wave, int_nablaG_wave                                &
          )

          int_G = int_G + coeffs(3) * int_G_wave
          int_nablaG(:) = int_nablaG(:) + coeffs(3) * int_nablaG_wave

        end if

        !!!!!!!!!!!!!!!!!!!
        !  Add to matrix  !
        !!!!!!!!!!!!!!!!!!!
        S(I, J) = int_G

        if (size(K, 3) == 1) then  ! early_dot_product=True
          if (adjoint_double_layer) then
            K(I, J, 1) = DOT_PRODUCT(dot_product_normals(I, :), int_nablaG(:))
          else
            K(I, J, 1) = DOT_PRODUCT(dot_product_normals(J, :), int_nablaG(:))
          endif
        else
          K(I, J, :) = int_nablaG(:)
        endif

      end do  ! loop on I
    end do  ! parallelized loop on J


!    IF ((coeffs(3) .NE. ZERO) .AND. use_symmetry_of_wave_part) THEN
!      ! If we are computing the influence of some cells upon themselves, the resulting matrices have some symmetries.
!      ! This is due to the symmetry of the Green function, and the way the integral on the face is approximated.
!      ! (More precisely, the Green function is symmetric and its derivative is the sum of a symmetric part and an anti-symmetric
!      ! part.)
!
!      !$OMP PARALLEL DO SCHEDULE(DYNAMIC) PRIVATE(J, I, int_G_wave, int_nablaG_wave, int_nablaG_wave_sym, int_nablaG_wave_antisym)
!      DO J = 1, nb_faces_2
!        DO I = J, nb_faces_1
!
!          call INTEGRAL_OF_WAVE_PART(                                    &
!            centers_1(I, :),                                             &
!            centers_2(J, :), areas_2(J),                                 &
!            quad_points(J, :, :), quad_weights(J, :),                    &
!            wavenumber, depth,                                           &
!            tabulation_nb_integration_points, tabulation_grid_shape,     &
!            tabulated_r_range, tabulated_z_range, tabulated_integrals,   &
!            gf_singularities,                                            &
!            finite_depth_method, prony_decomposition, dispersion_roots,  &
!            int_G_wave, int_nablaG_wave_sym, int_nablaG_wave_antisym     &
!          )
!
!          S(I, J) = S(I, J) + coeffs(3) * int_G_wave
!
!          IF (adjoint_double_layer) THEN
!            int_nablaG_wave(:) = int_nablaG_wave_sym(:) + int_nablaG_wave_antisym(:)
!          ELSE
!            int_nablaG_wave(:) = int_nablaG_wave_sym(:) - int_nablaG_wave_antisym(:)
!          END IF
!
!          if (size(K, 3) == 1) then
!            if (.NOT. adjoint_double_layer) then
!              K(I, J, 1) = K(I, J, 1) + coeffs(3) * DOT_PRODUCT(dot_product_normals(J, :), int_nablaG_wave(:))
!            else
!              K(I, J, 1) = K(I, J, 1) + coeffs(3) * DOT_PRODUCT(dot_product_normals(I, :), int_nablaG_wave(:))
!            endif
!          else
!            K(I, J, :) = K(I, J, :) + coeffs(3) * int_nablaG_wave(:)
!          endif
!
!          IF (.NOT. I==J) THEN
!
!            IF (.NOT. adjoint_double_layer) THEN
!              int_nablaG_wave(:) = int_nablaG_wave_sym(:) + int_nablaG_wave_antisym(:)
!            ELSE
!              int_nablaG_wave(:) = int_nablaG_wave_sym(:) - int_nablaG_wave_antisym(:)
!            END IF
!
!            S(J, I) = S(J, I) + coeffs(3) * int_G_wave * areas_2(I)/areas_2(J)
!            if (size(K, 3) == 1) then
!              if (.NOT. adjoint_double_layer) then
!                K(J, I, 1) = K(J, I, 1) + coeffs(3) * DOT_PRODUCT(dot_product_normals(I, :), int_nablaG_wave(:)) * &
!                  areas_2(I)/areas_2(J)
!              else
!                K(J, I, 1) = K(J, I, 1) + coeffs(3) * DOT_PRODUCT(dot_product_normals(J, :), int_nablaG_wave(:)) * &
!                  areas_2(I)/areas_2(J)
!              endif
!            else
!              K(J, I, :) = K(J, I, :) + coeffs(3) * int_nablaG_wave(:) * areas_2(I)/areas_2(J)
!            endif
!          END IF
!        END DO
!      END DO
!    END IF

  end subroutine

end module matrices
