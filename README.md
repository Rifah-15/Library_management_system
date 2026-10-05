# Library_management_system

A desktop-based Library Management System developed using Java Swing and MySQL. The system manages books, physical book copies, members, borrowing, returns, renewals, reservations, overdue records, and fines through a connected database.

## Features

### 1. Staff Login
- Staff authentication system
- First-time password setup
- Password stored using SHA-256 hashing
- Active staff verification

### 2. Dashboard
The dashboard provides an overview of:
- Total book titles
- Total book copies
- Available copies
- Lost/Damaged copies
- Total members
- Currently issued books
- Overdue books
- Active reservations
- Outstanding fines
- Today's collected payments

### 3. Book Management
- Add new books
- Add additional physical copies
- Search books by: Title, Author, ISBN, Category
- Manage publisher, category, author, and shelf information
- Generate a unique barcode for each physical book copy

### 4. Book Issue
The system allows staff to issue available books to active members.

Before issuing a book, the system checks:
- Member status
- Outstanding/overdue conditions
- Book availability
- Reservation status

### 5. Return & Renewal
Staff can:
- Return books
- Renew active loans
- Mark returned copies as: Good, Damaged, Lost

The system automatically updates the copy status and calculates applicable fines.

### 6. Reservation
Members can reserve books when no copy is currently available.

The system supports:
- Reservation queue
- Pending and Ready statuses
- Reservation cancellation
- Automatic promotion of the next reservation
- A 3-day holding period for a ready reservation

### 7. Fine Management
The system handles:
- Overdue fines
- Damage fines
- Lost-book fines
- Partial payments
- Multiple payment methods
- Payment reference numbers

Current fine rules:
- Overdue: 5.00 per day
- Damaged book: 100.00
- Lost book: 300.00

### 8. Member Management
Staff can:
- Add members
- View member information
- Suspend members
- Activate members
- Apply different borrowing rules based on member type

### 9. Overdue Management
The system provides an overdue-books view to help staff identify books that have passed their due dates.

---

## Technologies Used

- Java
- Java Swing
- JDBC
- MySQL
- MySQL Connector/J
- PreparedStatement
- SHA-256
- Transactions and Rollback

---

## Database Design

The system uses a relational MySQL database named: `library_db`

Main tables include:
- Staff
- Member
- MemberType
- Book
- BookCopy
- Author
- BookAuthor
- Publisher
- Category
- Shelf
- IssueRecord
- Reservation
- Fine
- FinePayment

The database also uses a view for overdue-book information and database triggers where required for data integrity and reservation handling.

### Database Relationships
- A Book can have multiple physical BookCopy records.
- A Book can be associated with an Author through BookAuthor.
- A Book belongs to a Category and can be assigned to a Shelf.
- A Member belongs to a MemberType.
- An IssueRecord connects members with borrowed book copies.
- A Reservation maintains the waiting queue for unavailable books.
- A Fine can have associated FinePayment records.

This relational structure helps reduce unnecessary data duplication and keeps the system organized.

---

## Project Structure

```text
Library Management System
│
├── LibraryApp.java
├── DBConnection.java
├── library_db.sql
├── library_extras.sql
└── README.md
