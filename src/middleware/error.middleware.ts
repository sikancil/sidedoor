import { Elysia } from 'elysia';

export const errorHandler = new Elysia({ name: 'error-handler' })
  .onError(({ code, error, set }) => {
    // Handle validation errors
    if (code === 'VALIDATION') {
      set.status = 400;
      return {
        success: false,
        error: 'Validation failed',
        details: error.message,
      };
    }

    // Handle not found
    if (code === 'NOT_FOUND') {
      set.status = 404;
      return {
        success: false,
        error: 'Resource not found',
      };
    }

    // Handle unauthorized
    if (error.message.includes('Unauthorized')) {
      set.status = 401;
      return {
        success: false,
        error: error.message,
      };
    }

    // Handle other errors
    set.status = 500;
    console.error('Error:', error);

    return {
      success: false,
      error: 'Internal server error',
      message: error.message,
    };
  });
