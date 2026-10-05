# Library Management System

A desktop-based Library Management System developed using **Java Swing** and **MySQL**. The system manages books, physical book copies, members, borrowing, returns, renewals, reservations, overdue records, and fines through a connected database.

## Features

### 1. Staff Login
- Staff authentication system
- First-time password setup
- Password stored using SHA-256 hashing
- Active staff verification

### 2. Dashboard
- Total book titles and total copies
- Available and lost/damaged copies
- Total members
- Currently issued books and overdue books
- Active reservations
- Outstanding fines and today's collected payments

### 3. Book Management
- Add new books and additional physical copies
- Search by title, author, ISBN or category
- Author, publisher and category are created automatically if they do not exist; shelf is selected from a list
- Unique barcode generated for each physical copy

### 4. Book Issue
Staff can issue available books to active members. Before issuing, the system checks:
- Member status
- Overdue books and unpaid fines
- Book availability and the member type's book limit
- Reservations held for other members

### 5. Return & Renewal
- Return books and mark the copy as **Good**, **Damaged** or **Lost**
- Renew active loans
- Copy status is updated and fines are calculated automatically

### 6. Reservation
Members can reserve a book when no copy is available.
- Reservation queue with Pending and Ready statuses
- Reservation cancellation
- Automatic promotion of the next reservation
- 3-day holding period for a Ready reservation

### 7. Fine Management
- Overdue, damaged-book and lost-book fines
- Partial payments (Cash, bKash, Card)
- Payment reference numbers

| Rule | Amount |
|------|--------|
| Overdue | 5.00 per day |
| Damaged book | 100.00 |
| Lost book | 300.00 |

### 8. Member Management
- Add members and view member information
- Suspend or activate members
- Different borrowing rules (loan period, book limit, renewals) by member type: Student, Teacher, General

### 9. Overdue Management
An overdue-books list with estimated fines helps staff find books that have passed their due dates.

---

## Technologies Used

- Java, Java Swing
- JDBC, MySQL Connector/J
- MySQL / MariaDB
- PreparedStatement, Transactions and Rollback
- SHA-256

---

## Database Design

The system uses a relational MySQL database named `library_db`.

**Main tables:** Staff, Member, MemberType, Book, BookCopy, Author, BookAuthor, Publisher, Category, Shelf, IssueRecord, Reservation, Fine, FinePayment, AuditLog

The database also contains **views** (overdue books, fine collection, popular books and more), **stored procedures and functions**, **triggers** for data integrity and reservation handling, and an hourly **event** that expires old reservations.

### Relationships
- A Book can have multiple physical BookCopy records.
- A Book is linked to Authors through BookAuthor.
- A Book belongs to a Category; each BookCopy is placed on a Shelf.
- A Member belongs to a MemberType.
- An IssueRecord connects a member with a borrowed book copy.
- A Reservation keeps the waiting queue for unavailable books.
- A Fine can have many FinePayment records.

---

## Project Structure

```text
Library_management_system/
├── src/
│   ├── LibraryApp.java
│   ├── DBConnection.java
│   └── TestConnection.java
├── nbproject/
├── library_db.sql
├── build.xml
└── README.md
```

---

## How to Run

### Prerequisites
1. JDK
2. MySQL Server (XAMPP or MySQL Workbench)
3. NetBeans IDE
4. MySQL Connector/J

### Database Setup
1. Start MySQL Server.
2. Import `library_db.sql` (phpMyAdmin or MySQL Workbench). It creates the `library_db` database with all tables, sample data, views, procedures and triggers.

### Configure Database Connection
Update the host, port, username and password in `DBConnection.java` to match your local MySQL.

### Run the Application
1. Open the project in NetBeans.
2. Add the MySQL Connector/J library.
3. Run `TestConnection.java` to verify the connection.
4. Run `LibraryApp.java`.

---

## Business Rules

- Only active members can borrow books.
- A book cannot be issued if no suitable copy is available.
- Members with overdue books or unpaid fines cannot borrow.
- Renewal depends on the member type's maximum renewals, and is blocked for overdue loans or when another member has reserved the book.
- Damaged and lost copies receive penalties on top of any late fine.
- Reservation queues are processed in order.
- Ready reservations are held for a limited time.
- Fine payments can be partial and are recorded separately.

---

## Data Integrity & Security

- Primary keys, foreign keys and unique keys
- Prepared statements to prevent SQL injection
- Transactions with rollback for important operations
- Database triggers for integrity rules
- SHA-256 password hashing
- Audit log of issue, return and payment events
- Input validation in the application

---

## User Interface

The Swing application has eight tabs: **Dashboard, Books, Issue Book, Return / Renew, Reservations, Fines, Members, Overdue**.

---

## Future Improvements

- Multiple-author management through the UI
- Barcode scanner integration
- Email/SMS notifications
- Advanced reporting and exportable reports
- More detailed staff roles and permissions
- Audit log viewer in the UI

---

## Conclusion

The Library Management System provides a practical, database-driven solution for common library operations. By combining a Java Swing interface with a relational MySQL database, it supports book and copy management, members, borrowing, returns, renewals, reservations, overdue tracking and fine payments in one application. Separating books from physical copies makes it a realistic academic project.
